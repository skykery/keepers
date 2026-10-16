import SwiftUI

@main
struct KeepersApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Keepers") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                    .disabled(model.isProcessing)
                Menu("Open Recent") {
                    ForEach(model.recentFolders, id: \.self) { url in
                        Button(url.lastPathComponent) { model.open(url) }
                    }
                    if !model.recentFolders.isEmpty {
                        Divider()
                        Button("Clear Menu") { model.clearRecents() }
                    }
                }
                .disabled(model.isProcessing || model.recentFolders.isEmpty)
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
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .setup: SetupView()
            case .processing: ProcessingView()
            case .workspace: WorkspaceView()
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
