import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import KeepersCore

enum Fixtures {
    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepers-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A gray image: a checkerboard of `cell`-pixel squares, optionally box-blurred.
    static func checkerboard(width: Int = 512, height: Int = 384, cell: Int = 8,
                             blurRadius: Int = 0, low: UInt8 = 40, high: UInt8 = 215) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = ((x / cell + y / cell) % 2 == 0) ? low : high
            }
        }
        if blurRadius > 0 { pixels = boxBlur(pixels, width, height, blurRadius) }
        return gray(pixels, width, height)
    }

    static func flat(width: Int = 256, height: Int = 256, value: UInt8) -> CGImage {
        gray([UInt8](repeating: value, count: width * height), width, height)
    }

    static func gray(_ pixels: [UInt8], _ width: Int, _ height: Int) -> CGImage {
        let data = Data(pixels) as CFData
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    static func boxBlur(_ p: [UInt8], _ w: Int, _ h: Int, _ r: Int) -> [UInt8] {
        var src = p, out = p
        src.withUnsafeMutableBytes { s in
            out.withUnsafeMutableBytes { o in
                var a = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var b = vImage_Buffer(data: o.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                let side = UInt32(2 * r + 1)
                _ = vImageBoxConvolve_Planar8(&a, &b, nil, 0, 0, side, side, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return out
    }

    @discardableResult
    static func writeJPEG(_ image: CGImage, to url: URL, exifDate: String? = nil) throws -> URL {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var props: [CFString: Any] = [:]
        if let exifDate { props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: exifDate] }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    static func touch(_ url: URL, _ contents: String = "x") throws {
        try contents.data(using: .utf8)!.write(to: url)
    }

    static func analysis(date: TimeInterval = 0, focus: Double = 60, aesthetics: Double? = 0.7,
                         faces: [PhotoAnalysis.Face] = [], print: FeaturePrint? = nil,
                         highlightClip: Double = 0, shadowClip: Double = 0, luminance: Double = 0.5) -> PhotoAnalysis {
        PhotoAnalysis(
            captureDate: Date(timeIntervalSince1970: date), pixelWidth: 2048, pixelHeight: 1365,
            subject: NormRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            subjectFocus: focus, globalFocus: focus,
            exposure: .init(highlightClip: highlightClip, shadowClip: shadowClip, subjectLuminance: luminance),
            aesthetics: aesthetics, isUtility: false, faces: faces, featurePrint: print
        )
    }

    static func face(quality: Double = 0.6, smiling: Bool? = false, eyesClosed: Bool? = false,
                     rect: NormRect = NormRect(x: 0.4, y: 0.3, width: 0.2, height: 0.25)) -> PhotoAnalysis.Face {
        PhotoAnalysis.Face(rect: rect, quality: quality, focus: 60, smiling: smiling,
                           eyesClosed: eyesClosed, isSubject: true)
    }
}
