import Foundation

/// One folder of photos being culled: analysis, decisions, manual moves.
public final class CullSession {
    public struct Progress: Sendable {
        public var done: Int
        public var total: Int
        public var current: String?
        public init(done: Int, total: Int, current: String?) {
            self.done = done; self.total = total; self.current = current
        }
    }

    public let inputDirectory: URL
    public let outputDirectory: URL
    public let photos: [Photo]
    public let store: SessionStore
    public let organizer: FolderOrganizer

    public private(set) var analyses: [String: PhotoAnalysis] = [:]
    public private(set) var failures: [String: String] = [:]
    public private(set) var result = CullResult(scores: [:], decisions: [:], groups: [])
    public private(set) var preset: Preset = .balanced

    public init(inputDirectory: URL, outputDirectory: URL? = nil) throws {
        self.inputDirectory = inputDirectory
        self.outputDirectory = outputDirectory ?? inputDirectory
        photos = try PhotoLibrary.scan(inputDirectory)
        store = SessionStore(outputDirectory: self.outputDirectory)
        organizer = FolderOrganizer(outputDirectory: self.outputDirectory)
    }

    public var pendingCount: Int { photos.filter { store.analysis(for: $0) == nil }.count }

    /// Analyzes every photo not already cached, `concurrency` at a time.
    public func analyze(fresh: Bool = false, analyzer: Analyzer = Analyzer(),
                        concurrency: Int = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1)),
                        progress: @escaping (Progress) -> Void = { _ in }) async throws {
        if fresh { store.removeAllAnalyses() }
        var todo: [Photo] = []
        for photo in photos {
            if let cached = store.analysis(for: photo) { analyses[photo.name] = cached } else { todo.append(photo) }
        }
        let total = photos.count
        var done = total - todo.count
        progress(Progress(done: done, total: total, current: nil))

        try await withThrowingTaskGroup(of: (Photo, Result<PhotoAnalysis, Error>).self) { group in
            var queue = todo[...]
            func enqueue() {
                guard let photo = queue.popFirst() else { return }
                group.addTask { (photo, Result { try analyzer.analyze(photo) }) }
            }
            for _ in 0..<concurrency { enqueue() }
            var lastSave = Date()
            while let (photo, outcome) = try await group.next() {
                try Task.checkCancellation()
                switch outcome {
                case .success(let analysis):
                    analyses[photo.name] = analysis
                    failures[photo.name] = nil
                    store.setAnalysis(analysis, for: photo)
                case .failure(let error):
                    failures[photo.name] = String(describing: error)
                }
                done += 1
                // The file is rewritten whole, so save on a timer rather than
                // per N photos: a large shoot's cache is tens of MB.
                if Date().timeIntervalSince(lastSave) > 10 { try? store.saveAnalyses(); lastSave = Date() }
                progress(Progress(done: done, total: total, current: photo.name))
                enqueue()
            }
        }
        try store.saveAnalyses()
    }

    /// Recomputes decisions for `preset` and syncs the output folders.
    /// Cheap: no image work, so changing the preset is instant.
    @discardableResult
    public func decide(preset: Preset) throws -> CullResult {
        self.preset = preset
        result = Culler.cull(analyses, preset: preset)
        try syncFolders()
        return result
    }

    public func folder(of name: String) -> Folder? {
        store.placements[name] ?? result.decisions[name]?.folder
    }

    public func isManual(_ name: String) -> Bool { store.placements[name] != nil }

    /// Pins a photo to a folder by hand. Pass nil to hand it back to the engine.
    public func move(_ name: String, to folder: Folder?) throws {
        try store.setPlacement(folder, for: name)
        guard let photo = photosByName[name], let target = self.folder(of: name) else { return }
        try organizer.place(photo, in: target)
    }

    private lazy var photosByName = Dictionary(photos.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

    private func syncFolders() throws {
        var placement: [Photo: Folder] = [:]
        for photo in photos {
            if let folder = folder(of: photo.name) { placement[photo] = folder }
        }
        try organizer.apply(placement)
    }
}
