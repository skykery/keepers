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

    @Published private(set) var items: [PhotoItem] = []
    @Published var tab: Folder = .picks
    @Published var selection: String?
    @Published var inspectorVisible = true
    @Published private(set) var failures: [String: String] = [:]

    private(set) var session: CullSession?
    private var work: Task<Void, Never>?

    init() {
        // `open -a Keepers --args --open <folder>` starts on that folder.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--open"), args.indices.contains(i + 1) {
            open(URL(fileURLWithPath: args[i + 1], isDirectory: true))
        }
    }

    var isProcessing: Bool { phase == .processing }

    var visibleItems: [PhotoItem] { items.filter { $0.folder == tab } }

    func count(_ folder: Folder) -> Int { items.filter { $0.folder == folder }.count }

    var selectedItem: PhotoItem? { items.first { $0.id == selection } }

    /// Other frames of the selected photo's group, best first.
    var groupOfSelection: [PhotoItem] {
        guard let item = selectedItem, let group = item.decision?.group, group >= 0,
              let names = session?.result.groups[safe: group], names.count > 1 else { return [] }
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return names.compactMap { byName[$0] }
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
        selection = nil
        if let url = folderURL { open(url) } else { phase = .setup }
    }

    // MARK: Workspace

    private func reloadItems() {
        guard let session else { items = []; return }
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

    /// Moves the selected photo by hand and advances to the next one in the tab.
    func moveSelection(to folder: Folder?) {
        guard let session, let item = selectedItem else { return }
        let visible = visibleItems
        let index = visible.firstIndex(of: item) ?? 0
        do {
            try session.move(item.id, to: folder)
            reloadItems()
            if session.folder(of: item.id) != tab {
                let remaining = visibleItems
                selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func step(_ delta: Int) {
        let visible = visibleItems
        guard !visible.isEmpty else { return }
        guard let current = visible.firstIndex(where: { $0.id == selection }) else {
            selection = visible.first?.id
            return
        }
        selection = visible[max(0, min(visible.count - 1, current + delta))].id
    }

    func select(tab: Folder) {
        self.tab = tab
        selection = visibleItems.first?.id
    }

    func reveal(_ folder: Folder) {
        guard let session else { return }
        NSWorkspace.shared.open(session.organizer.url(for: folder))
    }

    func revealOriginal(_ item: PhotoItem) {
        NSWorkspace.shared.activateFileViewerSelecting(item.photo.files)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
