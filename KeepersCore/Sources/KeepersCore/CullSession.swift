import Foundation

/// One folder of photos being culled: analysis, decisions, manual moves.
public final class CullSession {
    public struct Progress: Sendable {
        public var done: Int
        public var total: Int
        public var current: String?
        /// True while checking burst frames at full resolution.
        public var refining: Bool
        public init(done: Int, total: Int, current: String?, refining: Bool = false) {
            self.done = done; self.total = total; self.current = current; self.refining = refining
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
    public private(set) var settings: CullSettings = Preset.balanced.settings

    public init(inputDirectory: URL, outputDirectory: URL? = nil, includeSubfolders: Bool = false) throws {
        self.inputDirectory = inputDirectory
        self.outputDirectory = outputDirectory ?? inputDirectory
        photos = try PhotoLibrary.scan(inputDirectory, includeSubfolders: includeSubfolders)
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
        try await refineBursts(analyzer: analyzer, progress: progress)
        try await linkPanoramas(progress: progress)
    }

    /// For consecutive frames up to 5 s apart that look different enough to
    /// be panorama frames rather than a burst, measures how far the view
    /// moved (`PhotoAnalysis.panLink`). `Culler.panoramas` chains them.
    func linkPanoramas(progress: @escaping (Progress) -> Void) async throws {
        let ordered = photos.compactMap { p in analyses[p.name].map { (p, $0) } }
            .sorted { ($0.1.captureDate, $0.0.name) < ($1.1.captureDate, $1.0.name) }
        var todo: [(Photo, Photo)] = []
        for (prev, cur) in zip(ordered, ordered.dropFirst()) {
            let (pPhoto, pa) = prev, (cPhoto, ca) = cur
            guard ca.captureDate.timeIntervalSince(pa.captureDate) <= 5, ca.panLink?.previous != pPhoto.name,
                  ca.metadata?.exposureBias == pa.metadata?.exposureBias else { continue }
            if let a = pa.featurePrint, let b = ca.featurePrint, let d = a.distance(to: b), d < 0.12 { continue }
            todo.append((pPhoto, cPhoto))
        }
        guard !todo.isEmpty else { return }
        progress(Progress(done: 0, total: todo.count, current: nil, refining: true))
        for (i, (prev, cur)) in todo.enumerated() {
            try Task.checkCancellation()
            let shift = (try? Analyzer.translation(from: prev, to: cur)) ?? .zero
            if var a = analyses[cur.name] {
                a.panLink = PanLink(previous: prev.name, dx: Double(shift.dx), dy: Double(shift.dy))
                analyses[cur.name] = a
                store.setAnalysis(a, for: cur)
            }
            progress(Progress(done: i + 1, total: todo.count, current: cur.name, refining: true))
        }
        try store.saveAnalyses()
    }

    /// Measures the top frames of every multi-frame group at full detail
    /// (`PhotoAnalysis.detailFocus`), so the sharpest frame of a burst wins.
    /// Few photos and memory-heavy (large images), so it runs two at a time.
    func refineBursts(analyzer: Analyzer, progress: @escaping (Progress) -> Void) async throws {
        let gate = Preset.balanced.gate
        let scores = analyses.mapValues { Scorer.score($0, gate: gate) }
        let groups = BurstGrouper().group(analyses.map {
            BurstGrouper.Item(id: $0.key, date: $0.value.captureDate, print: $0.value.featurePrint)
        })
        func key(_ n: String) -> Double { scores[n]!.quality + (scores[n]!.face ?? 0) * ScoringWeights().faceInGroup }
        let todo = groups.filter { $0.count > 1 }
            .flatMap { $0.sorted { key($0) > key($1) }.prefix(3) }
            .filter { analyses[$0]?.detailFocus == nil }
            .compactMap { photosByName[$0] }
        guard !todo.isEmpty else { return }

        let snapshot = analyses
        var done = 0
        progress(Progress(done: 0, total: todo.count, current: nil, refining: true))
        try await withThrowingTaskGroup(of: (Photo, Double?).self) { group in
            var queue = todo[...]
            func enqueue() {
                guard let photo = queue.popFirst(), let a = snapshot[photo.name] else { return }
                group.addTask { (photo, try? analyzer.detailFocus(photo, analysis: a)) }
            }
            for _ in 0..<2 { enqueue() }
            while let (photo, value) = try await group.next() {
                try Task.checkCancellation()
                if let value, var a = analyses[photo.name] {
                    a.detailFocus = value
                    analyses[photo.name] = a
                    store.setAnalysis(a, for: photo)
                }
                done += 1
                progress(Progress(done: done, total: todo.count, current: photo.name, refining: true))
                enqueue()
            }
        }
        try store.saveAnalyses()
    }

    /// Recomputes decisions for `preset` and syncs the output folders.
    /// Cheap: no image work, so changing the preset is instant.
    @discardableResult
    public func decide(preset: Preset) throws -> CullResult {
        try decide(settings: preset.settings)
    }

    @discardableResult
    public func decide(settings: CullSettings) throws -> CullResult {
        self.settings = settings
        result = Culler.cull(analyses, settings: settings, overrides: store.groupOverrides)
        try syncFolders()
        return result
    }

    public func folder(of name: String) -> Folder? {
        store.placements[name] ?? result.decisions[name]?.folder
    }

    public func isManual(_ name: String) -> Bool { store.placements[name] != nil }

    public enum Regroup { case separate, splitHere, joinPrevious }

    /// Fixes the grouping of `name` by hand, then re-decides.
    public func regroup(_ name: String, _ action: Regroup) throws {
        var o = store.groupOverrides
        o.breaks.remove(name); o.joins.remove(name); o.separated.remove(name)
        switch action {
        case .separate: o.separated.insert(name)
        case .splitHere: o.breaks.insert(name)
        case .joinPrevious: o.joins.insert(name)
        }
        try store.setGroupOverrides(o)
        try decide(settings: settings)
    }

    /// Hands grouping of `name` back to the rules.
    public func clearGroupOverride(_ name: String) throws {
        var o = store.groupOverrides
        o.breaks.remove(name); o.joins.remove(name); o.separated.remove(name)
        try store.setGroupOverrides(o)
        try decide(settings: settings)
    }

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
