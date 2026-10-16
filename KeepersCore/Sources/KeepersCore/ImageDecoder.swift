import CoreGraphics
import Foundation
import ImageIO

public struct DecodedImage {
    public let image: CGImage
    public let captureDate: Date?
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
    public static func decode(_ url: URL, maxPixelSize: Int) throws -> DecodedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw Failure.unreadable(url)
        }
        var image = thumbnail(source, maxPixelSize: maxPixelSize, forceFullDecode: false)
        if let preview = image, max(preview.width, preview.height) < min(maxPixelSize, 1024) {
            image = thumbnail(source, maxPixelSize: maxPixelSize, forceFullDecode: true) ?? preview
        }
        guard let image else { throw Failure.unreadable(url) }
        return DecodedImage(image: image, captureDate: captureDate(source))
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
