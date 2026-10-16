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

    init() { cache.totalCostLimit = 512 * 1024 * 1024 }

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
}

final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
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
