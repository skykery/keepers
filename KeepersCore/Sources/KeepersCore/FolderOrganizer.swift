import Foundation

/// Mirrors decisions as symlinks in the four output folders. Originals are
/// never moved, renamed, or written.
public struct FolderOrganizer {
    public let outputDirectory: URL

    public init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    public func url(for folder: Folder) -> URL {
        outputDirectory.appendingPathComponent(folder.rawValue, isDirectory: true)
    }

    /// Makes the folders match `placement` exactly: links every file of each
    /// photo into its folder and removes any other symlinks we own.
    public func apply(_ placement: [Photo: Folder]) throws {
        let fm = FileManager.default
        var wanted: [Folder: [String: URL]] = [:]
        for (photo, folder) in placement {
            for file in photo.files { wanted[folder, default: [:]][file.lastPathComponent] = file }
        }
        for folder in Folder.allCases {
            let dir = url(for: folder)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let targets = wanted[folder] ?? [:]
            for existing in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                guard Self.isSymlink(existing) else { continue }
                let name = existing.lastPathComponent
                if let target = targets[name], Self.destination(of: existing) == target.path { continue }
                try fm.removeItem(at: existing)
            }
            for (name, target) in targets {
                let link = dir.appendingPathComponent(name)
                if Self.isSymlink(link) { continue }
                // A real file in our folder with this name belongs to the user; leave it.
                if fm.fileExists(atPath: link.path) { continue }
                try fm.createSymbolicLink(at: link, withDestinationURL: target)
            }
        }
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    static func destination(of link: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    }
}
