import AppKit
import KeepersCore
import SwiftUI

/// One row of the gallery.
struct PhotoItem: Identifiable, Hashable {
    var id: String { photo.name }
    let photo: Photo
    var folder: Folder
    var isManual: Bool
    let score: PhotoScore?
    let decision: Decision?
    let analysis: PhotoAnalysis?
}

struct FolderSummary {
    var photos = 0
    var raw = 0
    var pairs = 0
    var cached = 0
}

/// A manual move, for undo and redo. `nil` means automatic placement.
struct Move {
    let name: String
    let before: Folder?
    let after: Folder?
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase { case setup, processing, workspace }

    @Published var phase: Phase = .setup
    @Published var folderURL: URL?
    @Published var summary = FolderSummary()
    /// Also cull photos in subfolders (one per card or per day).
    @Published var includeSubfolders = UserDefaults.standard.bool(forKey: "includeSubfolders") {
        didSet {
            UserDefaults.standard.set(includeSubfolders, forKey: "includeSubfolders")
            if let folderURL, phase == .setup { open(folderURL) }
        }
    }
    /// Placements from a Keepers 1.x session in this folder, offered once.
    @Published private(set) var legacyPlacements: [String: Folder] = [:]
    /// Strict / Balanced / Lenient, or the photographer's own settings.
    enum Selectivity: Hashable, Identifiable {
        case preset(Preset)
        case custom

        static let all: [Selectivity] = [.preset(.strict), .preset(.balanced), .preset(.lenient), .custom]
        var id: String { title }
        var title: String {
            switch self {
            case .preset(let p): return p.title
            case .custom: return "Custom"
            }
        }
    }

    /// Remembered across launches, so reopening a folder doesn't silently
    /// re-sort it with different settings.
    @Published var selectivity: Selectivity = {
        let raw = UserDefaults.standard.string(forKey: "preset") ?? ""
        return raw == "custom" ? .custom : .preset(Preset(rawValue: raw) ?? .balanced)
    }() {
        didSet {
            switch selectivity {
            case .preset(let p): UserDefaults.standard.set(p.rawValue, forKey: "preset")
            case .custom: UserDefaults.standard.set("custom", forKey: "preset")
            }
            if phase == .workspace, selectivity != oldValue { redecide() }
        }
    }

    @Published var customSettings: CullSettings = AppModel.loadJSON("customSettings") ?? Preset.balanced.settings {
        didSet {
            AppModel.saveJSON(customSettings, "customSettings")
            if phase == .workspace, selectivity == .custom, customSettings != oldValue { redecide() }
        }
    }

    /// Weights learned from manual moves (see `Taste`), used when enabled.
    @Published var learnedWeights: ScoringWeights? = AppModel.loadJSON("learnedWeights") {
        didSet { AppModel.saveJSON(learnedWeights, "learnedWeights"); if phase == .workspace { redecide() } }
    }

    var effectiveSettings: CullSettings {
        var s: CullSettings
        switch selectivity {
        case .preset(let p): s = p.settings
        case .custom: s = customSettings
        }
        if let learnedWeights { s.weights = learnedWeights }
        return s
    }

    var selectivitySummary: String {
        let s = effectiveSettings
        return "Top \(Int((s.pickFraction * 100).rounded()))% of usable shots" + (learnedWeights != nil ? ", scored your way" : "")
    }

    static func loadJSON<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func saveJSON<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
    @Published var progress = CullSession.Progress(done: 0, total: 0, current: nil)
    @Published var errorMessage: String?
    @Published private(set) var recentFolders: [URL] = []

    /// All photos, best first; similar shots stay together.
    @Published private(set) var items: [PhotoItem] = []
    /// Photo names per folder, in `items` order.
    @Published private(set) var names: [Folder: [String]] = [:]
    @Published var tab: Folder = .picks
    @Published var selection: String?
    @Published var inspectorVisible = true
    @Published var showFailures = false
    @Published var showTaste = false
    /// Opt-in: the only network request Keepers makes.
    @Published var checkForUpdates = UserDefaults.standard.bool(forKey: "checkForUpdates") {
        didSet { UserDefaults.standard.set(checkForUpdates, forKey: "checkForUpdates") }
    }
    @Published var availableUpdate: ReleaseInfo?
    @Published private(set) var failures: [String: String] = [:]
    /// Full-screen viewer, and whether it compares a group side by side.
    enum Viewer { case single, compare }
    @Published var viewer: Viewer?
    @Published var zoomActual = false
    @Published var showFocusMap = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// Columns in the gallery grid, for ↑ / ↓. Set by the gallery's layout.
    var gridColumns = 1

    /// A long file operation in progress (export, ratings, card import).
    struct Activity {
        var title: String
        var done = 0
        var total = 0
        var cancellable = false
    }
    @Published var activity: Activity?
    /// A finished operation's summary, shown as an alert.
    struct Notice {
        var title: String
        var message: String
        var reveal: URL?
    }
    /// Set with `show(_:)`, so a new notice never reuses a visible alert.
    @Published var notice: Notice?

    func show(_ new: Notice) {
        guard notice != nil else { notice = new; return }
        notice = nil
        DispatchQueue.main.async { [weak self] in self?.notice = new }
    }
    /// Memory cards (volumes with a DCIM folder) currently mounted.
    @Published private(set) var cards: [CardImport.Card] = []
    var activityTask: Task<Void, Never>?
    private var volumeObservers: [NSObjectProtocol] = []

    private(set) var session: CullSession?
    private var work: Task<Void, Never>?
    private var index: [String: Int] = [:]
    private var undoStack: [Move] = []
    private var redoStack: [Move] = []

    init() {
        recentFolders = Self.loadRecents()
        refreshCards()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshCards() }
            })
        }
        // `open -a Keepers --args --open <folder>` starts on that folder.
        let args = ProcessInfo.processInfo.arguments
        if checkForUpdates { checkForUpdate(manual: false) }
        if let i = args.firstIndex(of: "--open"), args.indices.contains(i + 1) {
            open(URL(fileURLWithPath: args[i + 1], isDirectory: true))
        }
    }

    var isProcessing: Bool { phase == .processing }
    var isBusy: Bool { phase == .processing || activity != nil }
    /// Workspace actions (export, ratings, trash) are available.
    var canAct: Bool { phase == .workspace && activity == nil }

    func refreshCards() { cards = CardImport.cards() }

    var visibleItems: [PhotoItem] { (names[tab] ?? []).compactMap(item) }

    func count(_ folder: Folder) -> Int { names[folder]?.count ?? 0 }

    func item(_ name: String) -> PhotoItem? { index[name].map { items[$0] } }

    var selectedItem: PhotoItem? { selection.flatMap(item) }

    /// Up to four frames of the selected photo's group for side-by-side
    /// comparison: the best ones, always including the selection.
    var compareItems: [PhotoItem] {
        let group = groupOfSelection
        guard group.count > 1 else { return selectedItem.map { [$0] } ?? [] }
        var frames = Array(group.prefix(4))
        if let selected = selectedItem, !frames.contains(selected) { frames[frames.count - 1] = selected }
        return frames
    }

    // MARK: Viewer

    func openViewer(_ mode: Viewer, zoomed: Bool = false) {
        guard selectedItem != nil else { return }
        if mode == .compare, groupOfSelection.count < 2 { NSSound.beep(); return }
        viewer = mode
        zoomActual = zoomed
    }

    func closeViewer() {
        viewer = nil
        zoomActual = false
        // Compare can select a frame from another folder; show it there.
        if let name = selection, let item = item(name), item.folder != tab { tab = item.folder }
    }

    /// In compare, ← → move between the compared frames instead of the tab.
    func stepCompare(_ delta: Int) {
        let frames = compareItems.map(\.id)
        guard let i = frames.firstIndex(where: { $0 == selection }) else { selection = frames.first; return }
        selection = frames[max(0, min(frames.count - 1, i + delta))]
    }

    /// Frames of the selected photo's group, best first.
    var groupOfSelection: [PhotoItem] {
        guard let item = selectedItem, let group = item.decision?.group, group >= 0,
              let names = session?.result.groups[safe: group], names.count > 1 else { return [] }
        return names.compactMap(self.item)
    }

    // MARK: Setup

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder of photos to cull"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        work?.cancel()
        folderURL = url
        phase = .setup
        do {
            let photos = try PhotoLibrary.scan(url, includeSubfolders: includeSubfolders)
            let store = SessionStore(outputDirectory: url)
            summary = FolderSummary(
                photos: photos.count,
                raw: photos.filter(\.isRaw).count,
                pairs: photos.filter { !$0.companions.isEmpty }.count,
                cached: photos.filter { store.analysis(for: $0) != nil }.count
            )
            legacyPlacements = store.pendingLegacyPlacements(for: photos)
            remember(url)
        } catch {
            summary = FolderSummary()
            errorMessage = "Can't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Asks GitHub for the latest release: on launch at most once a day when
    /// enabled, or right away from the menu.
    func checkForUpdate(manual: Bool) {
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard manual || Date().timeIntervalSince1970 - last > 86_400 else { return }
        Task {
            var request = URLRequest(url: ReleaseInfo.latestURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let release = (try? await URLSession.shared.data(for: request)).flatMap { ReleaseInfo(json: $0.0) }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            if let release, release.isNewer(than: Self.currentVersion) {
                availableUpdate = release
            } else if manual {
                show(Notice(title: release == nil ? "Couldn't check for updates" : "Keepers is up to date",
                            message: release == nil ? "GitHub didn't answer. Try again later." : "You have the latest version, \(Self.currentVersion)."))
            }
        }
    }

    func resolveLegacy(importing: Bool) {
        guard let url = folderURL else { return }
        do {
            try SessionStore(outputDirectory: url).resolveLegacyPlacements(legacyPlacements, importing: importing)
            legacyPlacements = [:]
        } catch { errorMessage = error.localizedDescription }
    }

    func start(fresh: Bool) {
        guard let url = folderURL else { return }
        phase = .processing
        progress = .init(done: 0, total: summary.photos, current: nil)
        let settings = effectiveSettings
        work = Task {
            do {
                let session = try CullSession(inputDirectory: url, includeSubfolders: includeSubfolders)
                // `analyze` is nonisolated, so it runs off the main actor;
                // cancelling this task cancels it.
                try await session.analyze(fresh: fresh) { p in
                    Task { @MainActor [weak self] in self?.progress = p }
                }
                try Task.checkCancellation()
                try session.decide(settings: settings)
                self.session = session
                self.failures = session.failures
                undoStack = []; redoStack = []; updateUndoState()
                reloadItems()
                tab = count(.picks) > 0 ? .picks : .review
                selection = visibleItems.first?.id
                phase = .workspace
            } catch is CancellationError {
                phase = .setup
            } catch {
                errorMessage = error.localizedDescription
                phase = .setup
            }
        }
    }

    func cancel() {
        work?.cancel()
        phase = .setup
    }

    func newSession() {
        session = nil
        items = []
        names = [:]
        index = [:]
        selection = nil
        if let url = folderURL { open(url) } else { phase = .setup }
    }

    // MARK: Recent folders

    private static let recentsKey = "recentFolders"

    private static func loadRecents() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: recentsKey) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func remember(_ url: URL) {
        recentFolders = ([url] + recentFolders.filter { $0.standardizedFileURL != url.standardizedFileURL }).prefix(8).map { $0 }
        UserDefaults.standard.set(recentFolders.map(\.path), forKey: Self.recentsKey)
    }

    func clearRecents() {
        recentFolders = []
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
    }

    // MARK: Workspace

    private func reloadItems() {
        guard let session else { items = []; names = [:]; index = [:]; return }
        let r = session.result
        // Similar shots stay together, groups ordered by their best frame.
        func sortKey(_ name: String) -> (Double, Int, Int) {
            guard let d = r.decisions[name], d.group >= 0, let best = r.groups[safe: d.group]?.first else {
                return (r.scores[name]?.quality ?? 0, Int.max, 0)
            }
            return (r.scores[best]?.quality ?? 0, d.group, d.rankInGroup)
        }
        items = session.photos.compactMap { photo in
            guard let folder = session.folder(of: photo.name) else { return nil }
            return PhotoItem(photo: photo, folder: folder, isManual: session.isManual(photo.name),
                             score: r.scores[photo.name], decision: r.decisions[photo.name],
                             analysis: session.analyses[photo.name])
        }
        .sorted { a, b in
            let ka = sortKey(a.id), kb = sortKey(b.id)
            if ka.0 != kb.0 { return ka.0 > kb.0 }
            if ka.1 != kb.1 { return ka.1 < kb.1 }
            if ka.2 != kb.2 { return ka.2 < kb.2 }
            return a.id < b.id
        }
        index = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        rebuildNames()
    }

    private func rebuildNames() {
        var grouped: [Folder: [String]] = [:]
        for item in items { grouped[item.folder, default: []].append(item.id) }
        names = grouped
    }

    private func redecide() {
        guard let session else { return }
        do {
            try session.decide(settings: effectiveSettings)
            reloadItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Moves the selected photo by hand. In the grid and viewer, selection
    /// advances to the next photo in the tab; in compare it stays put.
    func moveSelection(to folder: Folder?) {
        guard let session, let item = selectedItem else { return }
        let before = session.store.placements[item.id]
        guard before != folder else { return }
        let visible = names[tab] ?? []
        let position = visible.firstIndex(of: item.id) ?? 0
        guard apply(Move(name: item.id, before: before, after: folder)) else { return }
        // Every deliberate move teaches the scoring (Taste); undo doesn't count.
        if let folder, let score = item.score { Taste.record(Taste.Sample(score, folder: folder)) }
        undoStack.append(Move(name: item.id, before: before, after: folder))
        redoStack = []
        updateUndoState()
        if viewer != .compare, self.item(item.id)?.folder != tab {
            let remaining = names[tab] ?? []
            selection = remaining.isEmpty ? nil : remaining[min(position, remaining.count - 1)]
        }
    }

    func undo() {
        guard let move = undoStack.popLast() else { return }
        guard apply(Move(name: move.name, before: move.after, after: move.before)) else { return }
        redoStack.append(move)
        updateUndoState()
        reveal(name: move.name)
    }

    func redo() {
        guard let move = redoStack.popLast() else { return }
        guard apply(move) else { return }
        undoStack.append(move)
        updateUndoState()
        reveal(name: move.name)
    }

    /// Applies a placement change to the session and to the one affected item.
    private func apply(_ move: Move) -> Bool {
        guard let session, let i = index[move.name] else { return false }
        do {
            try session.move(move.name, to: move.after)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        items[i].folder = session.folder(of: move.name) ?? items[i].folder
        items[i].isManual = session.isManual(move.name)
        rebuildNames()
        return true
    }

    private func updateUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Grouping by hand

    func regroupSelection(_ action: CullSession.Regroup) {
        guard let session, let name = selection else { return }
        do {
            try session.regroup(name, action)
            reloadItems()
        } catch { errorMessage = error.localizedDescription }
    }

    func resetGroupingOfSelection() {
        guard let session, let name = selection else { return }
        do {
            try session.clearGroupOverride(name)
            reloadItems()
        } catch { errorMessage = error.localizedDescription }
    }

    func hasGroupOverride(_ name: String) -> Bool {
        session?.store.groupOverrides.contains(name) ?? false
    }

    /// Shows `name` in its folder's tab and selects it.
    func reveal(name: String) {
        guard let item = item(name) else { return }
        tab = item.folder
        selection = name
    }

    func step(_ delta: Int) {
        let visible = names[tab] ?? []
        guard !visible.isEmpty else { return }
        guard let current = visible.firstIndex(where: { $0 == selection }) else {
            selection = visible.first
            return
        }
        selection = visible[max(0, min(visible.count - 1, current + delta))]
    }

    func select(tab: Folder) {
        self.tab = tab
        selection = names[tab]?.first
    }

    func reveal(_ folder: Folder) {
        guard let session else { return }
        NSWorkspace.shared.open(session.organizer.url(for: folder))
    }

    func revealOriginal(_ item: PhotoItem) {
        NSWorkspace.shared.activateFileViewerSelecting(item.photo.files)
    }

    func revealFailure(_ name: String) {
        guard let folderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folderURL.appendingPathComponent(name)])
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
