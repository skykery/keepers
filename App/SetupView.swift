import KeepersCore
import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("Keepers").font(.system(size: 34, weight: .bold))
                Text("Find your best shots. Everything stays on this Mac.")
                    .foregroundStyle(.secondary)
            }

            folderCard
            if model.folderURL != nil, model.summary.photos > 0 {
                presetPicker
                startButtons
            }
        }
        .padding(40)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
                Task { @MainActor in model.open(url) }
            }
            return true
        }
    }

    private var folderCard: some View {
        VStack(spacing: 12) {
            if let url = model.folderURL {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill").font(.title).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent).font(.headline)
                        Text(url.deletingLastPathComponent().path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Change…") { model.chooseFolder() }
                }
                Divider()
                summaryLine
            } else {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Drop a folder here, or").foregroundStyle(.secondary)
                Button("Choose Folder…") { model.chooseFolder() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(dropTargeted ? 1 : 0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropTargeted ? Color.accentColor : .clear, lineWidth: 2))
    }

    @ViewBuilder private var summaryLine: some View {
        let s = model.summary
        if s.photos == 0 {
            Label("No supported photos in this folder.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 18) {
                stat("\(s.photos)", "photos")
                stat("\(s.raw)", "RAW")
                if s.pairs > 0 { stat("\(s.pairs)", "RAW+JPEG pairs") }
                if s.cached > 0 { stat("\(s.cached)", "already analyzed") }
                Spacer()
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            Text(label).foregroundStyle(.secondary)
        }
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How selective?").font(.headline)
            Picker("How selective?", selection: $model.preset) {
                ForEach(Preset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("\(model.preset.summary). You can change this later without re-analyzing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var startButtons: some View {
        let s = model.summary
        HStack {
            if s.cached > 0 {
                Button("Re-analyze All") { model.start(fresh: true) }
            }
            Spacer()
            Button(s.cached == s.photos ? "Open Results" : s.cached > 0 ? "Continue (\(s.photos - s.cached) new)" : "Start Culling") {
                model.start(fresh: false)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }
}

struct ProcessingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Analyzing photos").font(.title2.weight(.semibold))
            ProgressView(value: Double(model.progress.done), total: Double(max(model.progress.total, 1)))
                .frame(width: 360)
            Text("\(model.progress.done) of \(model.progress.total)")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text(model.progress.current ?? " ").font(.caption).foregroundStyle(.tertiary)
            Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
