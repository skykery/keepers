import Foundation

/// Per-folder state, kept in `<output>/.keepers/`:
/// - `analysis.json`: measurements per photo, reused while the file is unchanged.
/// - `placements.json`: folders the user chose by hand. Automatic decisions
///   are never stored; they are recomputed from the analysis.
public final class SessionStore {
    public static let analysisVersion = 1

    struct Entry: Codable {
        var fileSize: Int
        var modified: Date
        var analysis: PhotoAnalysis
    }

    struct AnalysisFile: Codable {
        var version: Int
        var photos: [String: Entry]
    }

    public let directory: URL
    private var entries: [String: Entry] = [:]
    public private(set) var placements: [String: Folder] = [:]
    public private(set) var groupOverrides = GroupOverrides()
    private let lock = NSLock()

    public init(outputDirectory: URL) {
        directory = outputDirectory.appendingPathComponent(".keepers", isDirectory: true)
        load()
    }

    private var analysisURL: URL { directory.appendingPathComponent("analysis.json") }
    private var placementsURL: URL { directory.appendingPathComponent("placements.json") }
    private var groupingURL: URL { directory.appendingPathComponent("grouping.json") }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: analysisURL),
           let file = try? decoder.decode(AnalysisFile.self, from: data),
           file.version == Self.analysisVersion {
            entries = file.photos
        }
        if let data = try? Data(contentsOf: placementsURL),
           let file = try? decoder.decode([String: Folder].self, from: data) {
            placements = file
        }
        if let data = try? Data(contentsOf: groupingURL),
           let file = try? decoder.decode(GroupOverrides.self, from: data) {
            groupOverrides = file
        }
    }

    /// Cached analysis for `photo`, if the file hasn't changed since.
    public func analysis(for photo: Photo) -> PhotoAnalysis? {
        guard let stamp = Self.stamp(photo.primary) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[photo.name], e.fileSize == stamp.size,
              abs(e.modified.timeIntervalSince(stamp.modified)) < 1,
              (e.analysis.revision ?? 1) >= PhotoAnalysis.currentRevision else { return nil }
        return e.analysis
    }

    public func setAnalysis(_ analysis: PhotoAnalysis, for photo: Photo) {
        guard let stamp = Self.stamp(photo.primary) else { return }
        lock.lock(); defer { lock.unlock() }
        entries[photo.name] = Entry(fileSize: stamp.size, modified: stamp.modified, analysis: analysis)
    }

    public var cachedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    public func removeAllAnalyses() {
        lock.lock(); defer { lock.unlock() }
        entries = [:]
    }

    public func setPlacement(_ folder: Folder?, for name: String) throws {
        lock.lock()
        placements[name] = folder
        let snapshot = placements
        lock.unlock()
        try write(snapshot, to: placementsURL)
    }

    public func setGroupOverrides(_ overrides: GroupOverrides) throws {
        lock.lock()
        groupOverrides = overrides
        lock.unlock()
        try write(overrides, to: groupingURL)
    }

    // MARK: Keepers 1.x

    private var legacyURL: URL { directory.deletingLastPathComponent().appendingPathComponent("organization.json") }
    private var legacyHandledURL: URL { directory.appendingPathComponent("legacy-handled") }

    /// Placements from a Keepers 1.x `organization.json` not yet imported or
    /// dismissed. 1.x saved its automatic decisions there too, so these are
    /// offered, not applied.
    public func pendingLegacyPlacements(for photos: [Photo]) -> [String: Folder] {
        guard !FileManager.default.fileExists(atPath: legacyHandledURL.path),
              let data = try? Data(contentsOf: legacyURL),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        let names = Set(photos.map(\.name))
        var result: [String: Folder] = [:]
        for (name, value) in raw where names.contains(name) {
            if let folder = Folder(rawValue: value) { result[name] = folder }
        }
        return result
    }

    /// Imports the 1.x placements as manual ones (or not), and stops offering.
    public func resolveLegacyPlacements(_ legacy: [String: Folder], importing: Bool) throws {
        if importing {
            lock.lock()
            for (name, folder) in legacy where placements[name] == nil { placements[name] = folder }
            let snapshot = placements
            lock.unlock()
            try write(snapshot, to: placementsURL)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: legacyHandledURL)
    }

    public func saveAnalyses() throws {
        lock.lock()
        let file = AnalysisFile(version: Self.analysisVersion, photos: entries)
        lock.unlock()
        try write(file, to: analysisURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func stamp(_ url: URL) -> (size: Int, modified: Date)? {
        // URLs cache resource values; a long-lived session must see edits.
        var url = url
        url.removeAllCachedResourceValues()
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = v.fileSize, let modified = v.contentModificationDate else { return nil }
        return (size, modified)
    }
}
