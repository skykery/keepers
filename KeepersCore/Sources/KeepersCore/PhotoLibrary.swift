import Foundation

public enum PhotoFormats {
    public static let raw: Set<String> = ["orf", "nef", "dng", "cr2", "cr3", "arw", "rw2", "raf"]
    public static let rendered: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "tif", "tiff", "bmp", "gif"]
    public static let all = raw.union(rendered)

    public static func isRaw(_ url: URL) -> Bool { raw.contains(url.pathExtension.lowercased()) }
    public static func isSupported(_ url: URL) -> Bool { all.contains(url.pathExtension.lowercased()) }
}

/// One shot. A RAW+JPEG pair from the same exposure is a single photo: the RAW
/// is the primary file, the JPEG is decoded (it is the camera's own rendering
/// and much cheaper), and both get linked into the output folder.
public struct Photo: Hashable, Identifiable, Sendable {
    public var id: String { name }
    /// File name of the primary file, e.g. `P2241515.ORF`. Unique within a folder.
    public let name: String
    public let primary: URL
    public let companions: [URL]

    public var files: [URL] { [primary] + companions }
    public var isRaw: Bool { PhotoFormats.isRaw(primary) }

    /// The file to decode for analysis and thumbnails.
    public var decodeURL: URL {
        companions.first(where: { !PhotoFormats.isRaw($0) }) ?? primary
    }

    public init(primary: URL, companions: [URL] = []) {
        self.primary = primary
        self.companions = companions
        self.name = primary.lastPathComponent
    }
}

public enum PhotoLibrary {
    /// Lists the photos directly inside `folder` (not recursive), sorted by name.
    public static func scan(_ folder: URL) throws -> [Photo] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var byStem: [String: [URL]] = [:]
        for url in urls {
            // `._*` AppleDouble files on FAT/exFAT volumes carry photo
            // extensions but are metadata forks, not images.
            if url.lastPathComponent.hasPrefix("._") { continue }
            guard PhotoFormats.isSupported(url),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            byStem[url.deletingPathExtension().lastPathComponent.lowercased(), default: []].append(url)
        }

        var photos: [Photo] = []
        for (_, group) in byStem {
            let raws = group.filter(PhotoFormats.isRaw)
            let rendered = group.filter { !PhotoFormats.isRaw($0) }
            if raws.count == 1, rendered.count == 1 {
                photos.append(Photo(primary: raws[0], companions: rendered))
            } else {
                // Anything other than a clean pair stays separate.
                photos.append(contentsOf: group.map { Photo(primary: $0) })
            }
        }
        return photos.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
