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
    /// Remembered across launches, so reopening a folder doesn't silently
    /// re-sort it with a different preset.
    @Published var preset: Preset = Preset(rawValue: UserDefaults.standard.string(forKey: "preset") ?? "") ?? .balanced {
        didSet {
            UserDefaults.standard.set(preset.rawValue, forKey: "preset")
            if phase == .workspace, preset != oldValue { redecide() }
        }
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

    private(set) var session: CullSession?
    private var work: Task<Void, Never>?
    private var index: [String: Int] = [:]
    private var undoStack: [Move] = []
    private var redoStack: [Move] = []

    init() {
        recentFolders = Self.loadRecents()
        // `open -a Keepers --args --open <folder>` starts on that folder.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--open"), args.indices.contains(i + 1) {
            open(URL(fileURLWithPath: args[i + 1], isDirectory: true))
        }
    }

    var isProcessing: Bool { phase == .processing }

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
            let photos = try PhotoLibrary.scan(url)
            let store = SessionStore(outputDirectory: url)
            summary = FolderSummary(
                photos: photos.count,
                raw: photos.filter(\.isRaw).count,
                pairs: photos.filter { !$0.companions.isEmpty }.count,
                cached: photos.filter { store.analysis(for: $0) != nil }.count
            )
            remember(url)
        } catch {
            summary = FolderSummary()
            errorMessage = "Can't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func start(fresh: Bool) {
        guard let url = folderURL else { return }
        phase = .processing
        progress = .init(done: 0, total: summary.photos, current: nil)
        let preset = self.preset
        work = Task {
            do {
                let session = try CullSession(inputDirectory: url)
                // `analyze` is nonisolated, so it runs off the main actor;
                // cancelling this task cancels it.
                try await session.analyze(fresh: fresh) { p in
                    Task { @MainActor [weak self] in self?.progress = p }
                }
                try Task.checkCancellation()
                try session.decide(preset: preset)
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
            try session.decide(preset: preset)
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
