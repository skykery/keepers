import CoreGraphics
import Foundation
import ImageIO

public struct DecodedImage {
    public let image: CGImage
    public let captureDate: Date?
    public var metadata = CaptureMetadata()
}

/// Shooting details from EXIF and maker notes that change how a photo is judged.
public struct CaptureMetadata: Codable, Hashable, Sendable {
    /// Exposure compensation in EV; brackets vary it frame to frame.
    public var exposureBias: Double?
    /// Where the camera focused, upright and normalized (top-left origin).
    /// Only some cameras record it in a form macOS exposes (Nikon).
    public var focusPoint: NormRect?
    public init(exposureBias: Double? = nil, focusPoint: NormRect? = nil) {
        self.exposureBias = exposureBias; self.focusPoint = focusPoint
    }
}

public enum ImageDecoder {
    public enum Failure: Error, CustomStringConvertible {
        case unreadable(URL)
        public var description: String {
            switch self {
            case .unreadable(let url): return "Can't decode \(url.lastPathComponent)"
            }
        }
    }

    /// Decodes `url` upright with its long edge at most `maxPixelSize`.
    ///
    /// Prefers the embedded preview (RAW files carry a camera-rendered JPEG):
    /// on an ORF that is ~0.3 s instead of ~9 s for a full RAW develop. Falls
    /// back to a full decode when the embedded preview is too small to judge.
    ///
    /// With `exactSize`, the result is `maxPixelSize` (or the original's size,
    /// if smaller) even when that means developing the RAW: measurements like
    /// focus energy depend on resolution, and some cameras embed only a
    /// 1024 px preview (Olympus DNG). About 1 s per photo when it happens.
    public static func decode(_ url: URL, maxPixelSize: Int, exactSize: Bool = false) throws -> DecodedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw Failure.unreadable(url)
        }
        var needed = min(maxPixelSize, 1024)
        if exactSize {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let full = max(props?[kCGImagePropertyPixelWidth] as? Int ?? 0, props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
            needed = full > 0 ? min(maxPixelSize, full) : maxPixelSize
        }
        var image = thumbnail(source, maxPixelSize: maxPixelSize, forceFullDecode: false)
        if let preview = image, max(preview.width, preview.height) < needed {
            image = thumbnail(source, maxPixelSize: maxPixelSize, forceFullDecode: true) ?? preview
        }
        guard let image else { throw Failure.unreadable(url) }
        return DecodedImage(image: image, captureDate: captureDate(source), metadata: metadata(source))
    }

    /// Exposure compensation and focus point, without decoding pixels.
    public static func metadata(_ url: URL) -> CaptureMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return CaptureMetadata() }
        return metadata(source)
    }

    static func metadata(_ source: CGImageSource) -> CaptureMetadata {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return CaptureMetadata() }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return CaptureMetadata(
            exposureBias: (exif?[kCGImagePropertyExifExposureBiasValue] as? NSNumber)?.doubleValue,
            focusPoint: (aux?["AFInfo" as CFString] as? [Any]).flatMap { focusPoint(afInfo: $0, orientation: orientation) }
        )
    }

    /// ImageIO's AFInfo: groups of x, y, width, height, flag, where (x, y) is
    /// the point's corner — normalized, sensor orientation, taken as
    /// bottom-left origin like ImageIO's other normalized rects (the Nikon
    /// layouts seen are symmetric, so this couldn't be confirmed) — and "F"
    /// marks the points used.
    /// Returns the union of the used points, upright, top-left origin.
    static func focusPoint(afInfo: [Any], orientation: Int) -> NormRect? {
        var used: [NormRect] = []
        var i = 0
        while i + 4 < afInfo.count {
            let n = afInfo[i..<(i + 4)].compactMap { Double("\($0)") }
            if n.count == 4, "\(afInfo[i + 4])" == "F" {
                used.append(NormRect(bottomLeft: CGRect(x: n[0], y: n[1], width: n[2], height: n[3])))
            }
            i += 5
        }
        guard let first = used.first else { return nil }
        let r = used.dropFirst().reduce(first) { $0.union($1) }
        // EXIF orientations: 3 = 180°, 6 = 90° clockwise, 8 = 90° counterclockwise.
        switch orientation {
        case 3: return NormRect(x: 1 - r.x - r.width, y: 1 - r.y - r.height, width: r.width, height: r.height)
        case 6: return NormRect(x: 1 - r.y - r.height, y: r.x, width: r.height, height: r.width)
        case 8: return NormRect(x: r.y, y: 1 - r.x - r.width, width: r.height, height: r.width)
        default: return r
        }
    }

    /// An image for looking at closely, and how it relates to the original.
    public struct LargeImage {
        public let image: CGImage
        /// Upright pixel size of the original.
        public let nativeSize: CGSize
        /// True when `image` has the original's full resolution.
        public var isFullResolution: Bool { Double(max(image.width, image.height)) >= Double(max(nativeSize.width, nativeSize.height)) * 0.98 }
    }

    /// The largest image available quickly, or with `full`, the original at
    /// full resolution.
    ///
    /// For RAW files the quick image is the embedded preview at its own size:
    /// full resolution on many cameras (NEF), smaller on others (ORF previews
    /// are 3200 px). `full` develops the RAW, which can take seconds.
    public static func decodeLarge(_ url: URL, full: Bool) throws -> LargeImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { throw Failure.unreadable(url) }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let native = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if full || !PhotoFormats.isRaw(url) {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            options[kCGImageSourceThumbnailMaxPixelSize] = max(w, h)
        } else {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable(url)
        }
        return LargeImage(image: image, nativeSize: native)
    }

    static func thumbnail(_ source: CGImageSource, maxPixelSize: Int, forceFullDecode: Bool) -> CGImage? {
        let options: [CFString: Any] = [
            forceFullDecode ? kCGImageSourceCreateThumbnailFromImageAlways
                : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func captureDate(_ source: CGImageSource) -> Date? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        return parseExifDate(original, subseconds: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String)
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // EXIF has no zone. Only differences between photos matter, so any
        // fixed zone works as long as it is the same for all of them.
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    static func parseExifDate(_ value: String, subseconds: String?) -> Date? {
        guard let date = exifFormatter.date(from: value.trimmingCharacters(in: .whitespaces)) else { return nil }
        guard let digits = subseconds?.trimmingCharacters(in: .whitespaces), !digits.isEmpty,
              let fraction = Double("0." + digits)
        else { return date }
        return date.addingTimeInterval(fraction)
    }
}
