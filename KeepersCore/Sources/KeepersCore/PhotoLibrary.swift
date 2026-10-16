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

    /// Path of the photo's folder relative to the shoot folder; "" at its top.
    public let subfolder: String

    public init(primary: URL, companions: [URL] = [], subfolder: String = "") {
        self.primary = primary
        self.companions = companions
        self.subfolder = subfolder
        self.name = subfolder.isEmpty ? primary.lastPathComponent : "\(subfolder)/\(primary.lastPathComponent)"
    }

    /// The name of `file`'s link in an output folder. Photos from subfolders
    /// carry the subfolder as a prefix (`Day 2 - IMG_001.ORF`), so files with
    /// the same name from different cards don't collide.
    public func linkName(for file: URL) -> String {
        subfolder.isEmpty ? file.lastPathComponent
            : subfolder.replacingOccurrences(of: "/", with: " - ") + " - " + file.lastPathComponent
    }
}

public enum PhotoLibrary {
    /// Lists the photos in `folder`, sorted by name. With `includeSubfolders`,
    /// also in its subfolders, except hidden ones and Keepers' own output
    /// folders.
    public static func scan(_ folder: URL, includeSubfolders: Bool = false) throws -> [Photo] {
        var photos = try scanDirectory(folder, subfolder: "")
        if includeSubfolders {
            let own = Set(Folder.allCases.map(\.rawValue))
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
            let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
            let base = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            while let url = walker?.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                let parts = Array(url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.dropFirst(base.count))
                if let top = parts.first, own.contains(top) { walker?.skipDescendants(); continue }
                photos += try scanDirectory(url, subfolder: parts.joined(separator: "/"))
            }
        }
        return photos.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The photos directly inside `folder`, pairing RAW+JPEG.
    static func scanDirectory(_ folder: URL, subfolder: String) throws -> [Photo] {
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
                photos.append(Photo(primary: raws[0], companions: rendered, subfolder: subfolder))
            } else {
                // Anything other than a clean pair stays separate.
                photos.append(contentsOf: group.map { Photo(primary: $0, subfolder: subfolder) })
            }
        }
        return photos
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
