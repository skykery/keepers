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
