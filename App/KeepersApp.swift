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
