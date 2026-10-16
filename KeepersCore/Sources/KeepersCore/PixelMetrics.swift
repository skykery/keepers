import Accelerate
import CoreGraphics
import Foundation

/// A rectangle in normalized image coordinates, origin at the top-left.
public struct NormRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let full = NormRect(x: 0, y: 0, width: 1, height: 1)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// From Vision / Core Image normalized coordinates (origin bottom-left).
    public init(bottomLeft r: CGRect) {
        self.init(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    public var area: Double { width * height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func clamped() -> NormRect {
        let x0 = min(max(x, 0), 1), y0 = min(max(y, 0), 1)
        let x1 = min(max(x + width, 0), 1), y1 = min(max(y + height, 0), 1)
        return NormRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func union(_ o: NormRect) -> NormRect {
        let x0 = min(x, o.x), y0 = min(y, o.y)
        return NormRect(x: x0, y: y0, width: max(x + width, o.x + o.width) - x0,
                        height: max(y + height, o.y + o.height) - y0)
    }

    public func intersectionOverUnion(_ o: NormRect) -> Double {
        let ix = max(0, min(x + width, o.x + o.width) - max(x, o.x))
        let iy = max(0, min(y + height, o.y + o.height) - max(y, o.y))
        let inter = ix * iy
        let union = area + o.area - inter
        return union > 0 ? inter / union : 0
    }

    /// The band across a face box where the eyes sit.
    public var eyeBand: NormRect {
        NormRect(x: x + width * 0.1, y: y + height * 0.2, width: width * 0.8, height: height * 0.35)
    }
}

/// An image prepared for measurement: full-resolution luma, plus a small
/// RGBA copy for color statistics.
public struct PixelBuffer {
    public let width: Int
    public let height: Int
    /// Luma, 0...255, rows top to bottom.
    public let luma: [Float]

    /// Long edge of the color copy. Clipping fractions don't need full resolution.
    static let colorSide = 512
    let colorWidth: Int
    let colorHeight: Int
    /// 8-bit RGBX, rows top to bottom.
    let rgba: [UInt8]

    public init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height

        guard let gray = Self.render(image, width: width, height: height, channels: 1) else { return nil }
        luma = vDSP.integerToFloatingPoint(gray, floatingPointType: Float.self)

        let scale = min(1, Double(Self.colorSide) / Double(max(width, height)))
        colorWidth = max(1, Int(Double(width) * scale))
        colorHeight = max(1, Int(Double(height) * scale))
        guard let color = Self.render(image, width: colorWidth, height: colorHeight, channels: 4) else { return nil }
        rgba = color
    }

    private static func render(_ image: CGImage, width: Int, height: Int, channels: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * channels)
        let ok: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * channels,
                space: channels == 1 ? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)! : CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: channels == 1 ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? bytes : nil
    }

    func pixelRect(_ r: NormRect) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let c = r.clamped()
        let x0 = min(Int(c.x * Double(width)), width - 1), y0 = min(Int(c.y * Double(height)), height - 1)
        let x1 = max(x0 + 1, min(width, Int((c.x + c.width) * Double(width))))
        let y1 = max(y0 + 1, min(height, Int((c.y + c.height) * Double(height))))
        return (x0, y0, x1, y1)
    }
}

public enum PixelMetrics {
    /// Focus energy of the sharpest part of `region`: unbounded, 0 = flat.
    /// `Scorer.sharpness` maps it to 0...1.
    ///
    /// Smooths with a 3x3 Gaussian (to keep sensor noise from reading as
    /// detail), takes the Laplacian, and measures its variance per tile. A
    /// high-percentile tile counts, so a sharp subject against a soft
    /// background still scores high, while a frame with no sharp tile anywhere
    /// scores low.
    ///
    /// With `maxSide`, a larger region is downscaled to fit first, so a face
    /// measures the same whether it fills the frame or not. Smaller regions
    /// are never upscaled.
    public static func focusEnergy(_ px: PixelBuffer, in region: NormRect = .full,
                                   maxSide: Int? = nil, percentile: Double = 0.9) -> Double {
        guard let (lap, w, h) = laplacian(px, in: region, maxSide: maxSide) else { return 0 }
        var variances = tileVariances(lap, w, h, tile: max(16, min(w, h) / 8)).map(\.variance)
        guard !variances.isEmpty else { return 0 }
        variances.sort()
        return variances[min(variances.count - 1, Int(Double(variances.count) * percentile))]
    }

    /// Focus energy per tile over the whole frame, measured the same way as
    /// `focusEnergy`: where the photo is sharp.
    public struct FocusMap: Sendable {
        public let columns: Int
        public let rows: Int
        /// Row-major, top row first.
        public let energies: [Double]
        /// Tile size and the measured image's size, in pixels, to place tiles.
        public let tile: Int
        public let imageWidth: Int
        public let imageHeight: Int

        /// Sharpness (0...1, as scored) of the tile at `column`, `row`.
        public func sharpness(column: Int, row: Int) -> Double {
            Scorer.sharpness(energies[row * columns + column])
        }
    }

    public static func focusMap(_ px: PixelBuffer, tile: Int = 48) -> FocusMap {
        guard let (lap, w, h) = laplacian(px, in: .full, maxSide: nil) else {
            return FocusMap(columns: 0, rows: 0, energies: [], tile: tile, imageWidth: px.width, imageHeight: px.height)
        }
        let tiles = tileVariances(lap, w, h, tile: tile)
        let columns = tiles.map(\.column).max().map { $0 + 1 } ?? 0
        let rows = tiles.map(\.row).max().map { $0 + 1 } ?? 0
        var energies = [Double](repeating: 0, count: columns * rows)
        for t in tiles { energies[t.row * columns + t.column] = t.variance }
        return FocusMap(columns: columns, rows: rows, energies: energies, tile: tile, imageWidth: px.width, imageHeight: px.height)
    }

    /// Gaussian-smoothed Laplacian of `region`, optionally downscaled so its
    /// long side is at most `maxSide`.
    private static func laplacian(_ px: PixelBuffer, in region: NormRect, maxSide: Int?) -> ([Float], Int, Int)? {
        let (x0, y0, x1, y1) = px.pixelRect(region)
        let rw = x1 - x0, rh = y1 - y0
        let scale = maxSide.map { min(1, Double($0) / Double(max(rw, rh))) } ?? 1
        let w = Int(Double(rw) * scale), h = Int(Double(rh) * scale)
        guard w >= 8, h >= 8 else { return nil }

        var src = [Float](repeating: 0, count: w * h)
        var smooth = [Float](repeating: 0, count: w * h)
        var lap = [Float](repeating: 0, count: w * h)
        let rowBytes = w * MemoryLayout<Float>.stride

        px.luma.withUnsafeBufferPointer { luma in
            src.withUnsafeMutableBufferPointer { s in
                var region = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: luma.baseAddress! + y0 * px.width + x0),
                    height: vImagePixelCount(rh), width: vImagePixelCount(rw),
                    rowBytes: px.width * MemoryLayout<Float>.stride)
                var dest = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h),
                                         width: vImagePixelCount(w), rowBytes: rowBytes)
                if w == rw, h == rh {
                    _ = vImageCopyBuffer(&region, &dest, MemoryLayout<Float>.stride, vImage_Flags(kvImageNoFlags))
                } else {
                    _ = vImageScale_PlanarF(&region, &dest, nil, vImage_Flags(kvImageNoFlags))
                }
            }
        }
        convolve(&src, into: &smooth, w, h, kernel: [1, 2, 1, 2, 4, 2, 1, 2, 1].map { $0 / 16 })
        convolve(&smooth, into: &lap, w, h, kernel: [0, -1, 0, -1, 4, -1, 0, -1, 0])
        return (lap, w, h)
    }

    /// Variance of the Laplacian per tile, skipping the 1 px border the
    /// convolution extends.
    private static func tileVariances(_ lap: [Float], _ w: Int, _ h: Int, tile: Int) -> [(column: Int, row: Int, variance: Double)] {
        var result: [(column: Int, row: Int, variance: Double)] = []
        lap.withUnsafeBufferPointer { l in
            var ty = 1, row = 0
            while ty + 2 < h {
                let tyEnd = min(ty + tile, h - 1)
                var tx = 1, column = 0
                while tx + 2 < w {
                    let txEnd = min(tx + tile, w - 1)
                    let n = (tyEnd - ty) * (txEnd - tx)
                    if n >= 16 {
                        var sum: Float = 0, sumSq: Float = 0
                        for y in ty..<tyEnd {
                            var rs: Float = 0, rq: Float = 0
                            let p = l.baseAddress! + y * w + tx
                            vDSP_sve(p, 1, &rs, vDSP_Length(txEnd - tx))
                            vDSP_svesq(p, 1, &rq, vDSP_Length(txEnd - tx))
                            sum += rs; sumSq += rq
                        }
                        let mean = Double(sum) / Double(n)
                        result.append((column, row, max(0, Double(sumSq) / Double(n) - mean * mean)))
                    }
                    tx += tile; column += 1
                }
                ty += tile; row += 1
            }
        }
        return result
    }

    private static func convolve(_ src: inout [Float], into dst: inout [Float], _ w: Int, _ h: Int, kernel: [Float]) {
        let rowBytes = w * MemoryLayout<Float>.stride
        src.withUnsafeMutableBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                var a = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowBytes)
                var b = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowBytes)
                _ = vImageConvolve_PlanarF(&a, &b, nil, 0, 0, kernel, 3, 3, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
    }

    public struct Exposure: Codable, Hashable, Sendable {
        /// Fraction of pixels with any channel at or near 255.
        public var highlightClip: Double
        /// Fraction of pixels with luma at or near 0.
        public var shadowClip: Double
        /// Mean luma of the subject region, 0...1.
        public var subjectLuminance: Double
    }

    public static func exposure(_ px: PixelBuffer, subject: NormRect) -> Exposure {
        let n = px.colorWidth * px.colorHeight
        var blown = 0, black = 0
        px.rgba.withUnsafeBufferPointer { c in
            for i in 0..<n {
                let r = c[i * 4], g = c[i * 4 + 1], b = c[i * 4 + 2]
                if max(r, g, b) >= 250 { blown += 1 }
                if max(r, g, b) <= 8 { black += 1 }
            }
        }
        let (x0, y0, x1, y1) = px.pixelRect(subject)
        var sum: Float = 0
        px.luma.withUnsafeBufferPointer { l in
            for y in y0..<y1 {
                var rs: Float = 0
                vDSP_sve(l.baseAddress! + y * px.width + x0, 1, &rs, vDSP_Length(x1 - x0))
                sum += rs
            }
        }
        let mean = Double(sum) / Double((x1 - x0) * (y1 - y0)) / 255
        return Exposure(highlightClip: Double(blown) / Double(n), shadowClip: Double(black) / Double(n),
                        subjectLuminance: mean)
    }
}
