import AppKit
import ImageIO
import KeepersCore
import SwiftUI

/// Decodes and caches previews off the main thread. RAW files use their
/// embedded camera preview, so this stays fast even for large shoots.
/// NSCache is thread-safe; the queue only reads immutable inputs.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, CGImageBox>()
    private let queue = DispatchQueue(label: "keepers.thumbnails", qos: .userInitiated, attributes: .concurrent)

    init() {
        cache.totalCostLimit = 512 * 1024 * 1024
        large.totalCostLimit = 640 * 1024 * 1024
        maps.countLimit = 200
    }

    func cached(_ photo: Photo, size: Int) -> CGImage? {
        cache.object(forKey: Self.key(photo, size) as NSString)?.image
    }

    func image(for photo: Photo, size: Int) async -> CGImage? {
        let key = Self.key(photo, size)
        if let hit = cache.object(forKey: key as NSString) { return hit.image }
        return await withCheckedContinuation { continuation in
            queue.async {
                let key = key as NSString
                let image = try? ImageDecoder.decode(photo.decodeURL, maxPixelSize: size).image
                if let image {
                    self.cache.setObject(CGImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
                }
                continuation.resume(returning: image)
            }
        }
    }

    private static func key(_ photo: Photo, _ size: Int) -> String { "\(photo.decodeURL.path)#\(size)" }

    // MARK: Large images and focus maps, for the viewer

    private let large = NSCache<NSString, LargeImageBox>()
    private let maps = NSCache<NSString, FocusMapBox>()

    func cachedLarge(_ photo: Photo, full: Bool) -> ImageDecoder.LargeImage? {
        large.object(forKey: "\(photo.decodeURL.path)#\(full)" as NSString)?.value
            ?? (full ? nil : large.object(forKey: "\(photo.decodeURL.path)#true" as NSString)?.value)
    }

    /// The largest quick image, or with `full`, the original at full
    /// resolution (a RAW develop: can take seconds).
    func largeImage(for photo: Photo, full: Bool) async -> ImageDecoder.LargeImage? {
        if let hit = cachedLarge(photo, full: full) { return hit }
        let key = "\(photo.decodeURL.path)#\(full)"
        return await withCheckedContinuation { continuation in
            queue.async {
                let result = try? ImageDecoder.decodeLarge(photo.decodeURL, full: full)
                if let result {
                    let box = LargeImageBox(result)
                    let cost = result.image.bytesPerRow * result.image.height
                    self.large.setObject(box, forKey: key as NSString, cost: cost)
                    // A full-resolution image also serves as the quick one.
                    if result.isFullResolution {
                        self.large.setObject(box, forKey: "\(photo.decodeURL.path)#\(!full)" as NSString, cost: cost)
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// Where the photo is sharp, measured like the analysis does (2048 px).
    func focusMap(for photo: Photo) async -> PixelMetrics.FocusMap? {
        let key = photo.decodeURL.path
        if let hit = maps.object(forKey: key as NSString) { return hit.value }
        guard let image = await image(for: photo, size: Analyzer.workingSize) else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                let map = PixelBuffer(image).map { PixelMetrics.focusMap($0) }
                if let map { self.maps.setObject(FocusMapBox(map), forKey: key as NSString) }
                continuation.resume(returning: map)
            }
        }
    }
}

final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

final class LargeImageBox: @unchecked Sendable {
    let value: ImageDecoder.LargeImage
    init(_ value: ImageDecoder.LargeImage) { self.value = value }
}

final class FocusMapBox: @unchecked Sendable {
    let value: PixelMetrics.FocusMap
    init(_ value: PixelMetrics.FocusMap) { self.value = value }
}

struct PhotoImage: View {
    let photo: Photo
    let size: Int
    let contentMode: ContentMode

    @State private var image: CGImage?

    init(photo: Photo, size: Int, contentMode: ContentMode = .fill) {
        self.photo = photo
        self.size = size
        self.contentMode = contentMode
        _image = State(initialValue: ImageCache.shared.cached(photo, size: size))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(.quaternary)
                ProgressView().controlSize(.small)
            }
        }
        .task(id: photo.decodeURL.path + "#\(size)") {
            image = ImageCache.shared.cached(photo, size: size)
            if image == nil { image = await ImageCache.shared.image(for: photo, size: size) }
        }
    }
}
