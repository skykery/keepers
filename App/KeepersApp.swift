import AppKit
import KeepersCore
import SwiftUI

@main
struct KeepersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // One window: folders from Finder go to that window (via the app
        // delegate) instead of opening new ones.
        Window("Keepers", id: "main") {
            RootView()
                .environmentObject(delegate.model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands(model: delegate.model) }
    }
}

/// Receives folders from Finder: "Open With", a drop on the Dock icon, and
/// the "Cull with Keepers" service.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openFirstFolder(urls)
    }

    /// NSServices entry point (see `NSServices` in project.yml).
    @objc func cullFolder(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        openFirstFolder(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openFirstFolder(_ urls: [URL]) {
        guard let folder = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
        else { return }
        model.open(folder)
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") { model.chooseFolder() }
                .keyboardShortcut("o")
                .disabled(model.isBusy)
            Menu("Open Recent") {
                ForEach(model.recentFolders, id: \.self) { url in
                    Button(url.lastPathComponent) { model.open(url) }
                }
                if !model.recentFolders.isEmpty {
                    Divider()
                    Button("Clear Menu") { model.clearRecents() }
                }
            }
            .disabled(model.isBusy || model.recentFolders.isEmpty)
            Menu("Import from Card") {
                ForEach(model.cards) { card in
                    Button(card.name) { model.importCard(card) }
                }
            }
            .disabled(model.isBusy || model.cards.isEmpty)
        }
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Export Top Picks…") { model.export([.picks]) }
                .disabled(!model.canAct)
            Button("Export Top Picks and Moments…") { model.export([.picks, .moments]) }
                .disabled(!model.canAct)
            Button("Write Ratings to XMP Sidecars…") { model.writeRatings() }
                .disabled(!model.canAct)
            Divider()
            Button("Move Trash Originals to the Finder Trash…") { model.moveTrashToFinderTrash() }
                .disabled(!model.canAct || model.count(.trash) == 0)
        }
        CommandGroup(after: .appSettings) {
            Button("Learn From My Choices…") { model.showTaste = true }
            Divider()
            Button("Check for Updates…") { model.checkForUpdate(manual: true) }
            Toggle("Check for Updates Automatically", isOn: $model.checkForUpdates)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo Move") { model.undo() }
                .keyboardShortcut("z")
                .disabled(!model.canUndo)
            Button("Redo Move") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Group {
                switch model.phase {
                case .setup: SetupView()
                case .processing: ProcessingView()
                case .workspace: WorkspaceView()
                }
            }
            if let activity = model.activity { ActivityOverlay(activity: activity) }
        }
        .sheet(isPresented: Binding(get: { model.showTaste }, set: { model.showTaste = $0 })) { TasteView() }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(model.notice?.title ?? "", isPresented: Binding(
            get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }
        )) {
            if let reveal = model.notice?.reveal {
                Button("Show in Finder") { NSWorkspace.shared.open(reveal); model.notice = nil }
            }
            Button("OK", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice?.message ?? "")
        }
    }
}

/// Progress for export, rating, and card import.
struct ActivityOverlay: View {
    @EnvironmentObject private var model: AppModel
    let activity: AppModel.Activity

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                Text(activity.title).font(.headline)
                ProgressView(value: Double(activity.done), total: Double(max(activity.total, 1)))
                    .frame(width: 320)
                Text("\(activity.done) of \(activity.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if activity.cancellable {
                    Button("Cancel") { model.cancelActivity() }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
