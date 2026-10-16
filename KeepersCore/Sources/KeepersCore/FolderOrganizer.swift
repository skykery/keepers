import Foundation

/// Mirrors decisions as symlinks in the four output folders. Originals are
/// never moved, renamed, or written.
///
/// Links are relative (`../IMG_001.ORF`), so they keep working when the
/// shoot folder is moved, the drive is renamed, or it's opened on another Mac.
public struct FolderOrganizer {
    public let outputDirectory: URL

    public init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    public func url(for folder: Folder) -> URL {
        outputDirectory.appendingPathComponent(folder.rawValue, isDirectory: true)
    }

    /// Makes the folders match `placement` exactly: links every file of each
    /// photo into its folder and removes any other symlinks we own. Absolute
    /// links from earlier versions are replaced with relative ones.
    public func apply(_ placement: [Photo: Folder]) throws {
        let fm = FileManager.default
        var wanted: [Folder: [String: String]] = [:]
        for folder in Folder.allCases {
            let dir = url(for: folder)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (photo, f) in placement where f == folder {
                for file in photo.files { wanted[folder, default: [:]][file.lastPathComponent] = Self.relativePath(to: file, from: dir) }
            }
        }
        for folder in Folder.allCases {
            let dir = url(for: folder)
            let targets = wanted[folder] ?? [:]
            for existing in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                guard Self.isSymlink(existing) else { continue }
                if let target = targets[existing.lastPathComponent], Self.destination(of: existing) == target { continue }
                try fm.removeItem(at: existing)
            }
            for (name, target) in targets {
                try link(dir.appendingPathComponent(name), to: target)
            }
        }
    }

    /// Moves one photo's links into `folder`. Cheap: touches only that
    /// photo's files, so manual moves stay instant in large shoots.
    public func place(_ photo: Photo, in folder: Folder) throws {
        let fm = FileManager.default
        for other in Folder.allCases where other != folder {
            for file in photo.files {
                let link = url(for: other).appendingPathComponent(file.lastPathComponent)
                if Self.isSymlink(link) { try fm.removeItem(at: link) }
            }
        }
        let dir = url(for: folder)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in photo.files {
            let link = dir.appendingPathComponent(file.lastPathComponent)
            let target = Self.relativePath(to: file, from: dir)
            if Self.isSymlink(link), Self.destination(of: link) != target { try fm.removeItem(at: link) }
            try self.link(link, to: target)
        }
    }

    private func link(_ link: URL, to target: String) throws {
        let fm = FileManager.default
        if Self.isSymlink(link) { return }
        // A real file in our folder with this name belongs to the user; leave it.
        if fm.fileExists(atPath: link.path) { return }
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
    }

    /// Path of `file` relative to `directory`, e.g. `../IMG_001.ORF`.
    static func relativePath(to file: URL, from directory: URL) -> String {
        let from = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let to = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var common = 0
        while common < min(from.count, to.count), from[common] == to[common] { common += 1 }
        let ups = Array(repeating: "..", count: from.count - common)
        return (ups + to[common...]).joined(separator: "/")
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    static func destination(of link: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    }
}
