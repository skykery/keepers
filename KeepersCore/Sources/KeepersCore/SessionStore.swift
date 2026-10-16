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
    private let lock = NSLock()

    public init(outputDirectory: URL) {
        directory = outputDirectory.appendingPathComponent(".keepers", isDirectory: true)
        load()
    }

    private var analysisURL: URL { directory.appendingPathComponent("analysis.json") }
    private var placementsURL: URL { directory.appendingPathComponent("placements.json") }

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
    }

    /// Cached analysis for `photo`, if the file hasn't changed since.
    public func analysis(for photo: Photo) -> PhotoAnalysis? {
        guard let stamp = Self.stamp(photo.primary) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[photo.name], e.fileSize == stamp.size,
              abs(e.modified.timeIntervalSince(stamp.modified)) < 1 else { return nil }
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
        encoder.outputFormatting = [.sortedKeys]
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
