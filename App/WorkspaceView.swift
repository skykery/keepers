import AppKit
import KeepersCore
import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                GalleryView()
                if model.inspectorVisible, let item = model.selectedItem {
                    Divider()
                    InspectorView(item: item)
                        .frame(width: 360)
                }
            }
            switch model.viewer {
            case .single: ViewerView()
            case .compare: CompareView()
            case nil: EmptyView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.newSession() } label: { Label("Folders", systemImage: "chevron.backward") }
                    .help("Back to folder selection")
            }
            ToolbarItem(placement: .principal) {
                Picker("Folder", selection: Binding(get: { model.tab }, set: { model.select(tab: $0) })) {
                    ForEach(Folder.allCases) { folder in
                        Text("\(folder.rawValue)  \(model.count(folder))").tag(folder)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Preset", selection: $model.preset) {
                    ForEach(Preset.allCases) { Text($0.title).tag($0) }
                }
                .help("How selective Top Picks is. Your manual moves are kept.")
                Button { model.reveal(model.tab) } label: { Label("Show in Finder", systemImage: "folder") }
                    .help("Show \(model.tab.rawValue) in Finder")
                Button { model.inspectorVisible.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                    .help("Show or hide details (Return)")
            }
        }
        .navigationTitle(model.folderURL?.lastPathComponent ?? "Keepers")
        .onAppear { installKeyMonitor() }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only for the main window: leave keys alone in open panels,
            // sheets, menus, and text fields.
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  NSApp.modalWindow == nil,
                  let window = event.window, !(window is NSPanel),
                  window.attachedSheet == nil, window.sheetParent == nil,
                  !(window.firstResponder is NSText)
            else { return event }
            return handle(event) ? nil : event
        }
    }

    /// Keys for the grid, the full-screen viewer, and compare.
    private func handle(_ event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch model.viewer {
        case .some(let mode):
            switch event.keyCode {
            case 53: model.closeViewer(); return true                          // Esc
            case 49: if mode == .single { model.closeViewer() }; return true    // Space
            case 123: mode == .compare ? model.stepCompare(-1) : model.step(-1); return true
            case 124: mode == .compare ? model.stepCompare(1) : model.step(1); return true
            case 51, 117: model.moveSelection(to: .trash); return true
            default: break
            }
            switch key {
            case "z": model.zoomActual.toggle(); return true
            case "f": model.showFocusMap.toggle(); return true
            case "c": mode == .compare ? model.closeViewer() : model.openViewer(.compare); return true
            default: return moveKey(key)
            }
        case nil:
            switch event.keyCode {
            case 123: model.step(-1); return true                   // ←
            case 124: model.step(1); return true                    // →
            case 126: model.step(-model.gridColumns); return true   // ↑
            case 125: model.step(model.gridColumns); return true    // ↓
            case 36, 76: model.inspectorVisible.toggle(); return true  // Return
            case 53: model.inspectorVisible = false; return true    // Esc
            case 49: model.openViewer(.single); return true         // Space
            case 51, 117: model.moveSelection(to: .trash); return true  // Delete
            default: break
            }
            switch key {
            case "z": model.openViewer(.single, zoomed: true); return true
            case "c": model.openViewer(.compare); return true
            case "f": model.showFocusMap.toggle(); return true
            default: return moveKey(key)
            }
        }
    }

    private func moveKey(_ key: String?) -> Bool {
        switch key {
        case "p", "1": model.moveSelection(to: .picks)
        case "r", "2": model.moveSelection(to: .review)
        case "m", "3": model.moveSelection(to: .moments)
        case "x": model.moveSelection(to: .trash)
        case "u", "0": model.moveSelection(to: nil)
        default: return false
        }
        return true
    }
}

struct GalleryView: View {
    @EnvironmentObject private var model: AppModel
    private static let minCell: CGFloat = 170, spacing: CGFloat = 10, padding: CGFloat = 12
    private let columns = [GridItem(.adaptive(minimum: minCell, maximum: 240), spacing: spacing)]

    var body: some View {
        let items = model.visibleItems
        ScrollViewReader { proxy in
            ScrollView {
                if items.isEmpty {
                    emptyState.padding(.top, 120)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(items) { item in
                            ThumbnailCell(item: item, selected: item.id == model.selection)
                                .id(item.id)
                                .onTapGesture(count: 2) { model.selection = item.id; model.inspectorVisible = true }
                                .onTapGesture { model.selection = item.id }
                        }
                    }
                    .padding(12)
                }
            }
            .onChange(of: model.selection) { id in
                if let id { withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) } }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .background(GeometryReader { geo in
            // Same arithmetic as the adaptive grid, so ↑ / ↓ move one row.
            Color.clear.onAppear { updateColumns(geo.size.width) }
                .onChange(of: geo.size.width) { updateColumns($0) }
        })
        .safeAreaInset(edge: .bottom) {
            if !model.failures.isEmpty {
                Button { model.showFailures = true } label: {
                    Label("\(model.failures.count) file\(model.failures.count == 1 ? "" : "s") couldn't be read",
                          systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.borderless)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .sheet(isPresented: $model.showFailures) { FailuresSheet() }
    }

    private func updateColumns(_ width: CGFloat) {
        let usable = width - 2 * Self.padding
        model.gridColumns = max(1, Int((usable + Self.spacing) / (Self.minCell + Self.spacing)))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Nothing in \(model.tab.rawValue)").font(.headline)
            Text("P  Top Picks · M  Moments · R  Review · X  Trash · U  back to automatic")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct FailuresSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files Keepers couldn't read").font(.headline)
            Text("These aren't in any folder. If they're RAW files, this version of macOS may not support that camera yet; a macOS update usually adds it.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(model.failures.keys.sorted(), id: \.self) { name in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                        Text(model.failures[name] ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show in Finder") { model.revealFailure(name) }
                }
            }
            .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 380)
    }
}

struct ThumbnailCell: View {
    let item: PhotoItem
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The fixed-size container decides the layout; the filling image is
            // only drawn into it, so wide frames can't push the cell wider.
            Color.clear
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .overlay(PhotoImage(photo: item.photo, size: 480))
                .clipped()
                .overlay(alignment: .topLeading) { badges.padding(5) }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 4) {
                Text(item.photo.name).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if let q = item.score?.quality {
                    Text("\(Int((q * 100).rounded()))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 4) {
            if item.isManual { badge("hand.point.up.left.fill", help: "Placed by you") }
            if let d = item.decision, d.groupSize > 1 {
                Text("\(d.rankInGroup)/\(d.groupSize)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .help("Rank among \(d.groupSize) similar shots")
            }
            if let flaws = item.score?.flaws, !flaws.isEmpty {
                badge("eye.slash.fill", help: flaws.joined(separator: ", "))
            }
            if !item.photo.companions.isEmpty { badge("square.on.square", help: "RAW + JPEG") }
        }
    }

    private func badge(_ symbol: String, help: String) -> some View {
        Image(systemName: symbol)
            .font(.caption2)
            .padding(4)
            .background(.ultraThinMaterial, in: Circle())
            .help(help)
    }
}
