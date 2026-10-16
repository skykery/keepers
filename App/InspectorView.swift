import KeepersCore
import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var model: AppModel
    let item: PhotoItem
    @State private var focusMap: PixelMetrics.FocusMap?

    private var aspect: CGFloat {
        guard let a = item.analysis, a.pixelHeight > 0 else { return 1.5 }
        return CGFloat(a.pixelWidth) / CGFloat(a.pixelHeight)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PhotoImage(photo: item.photo, size: 1600, contentMode: .fit)
                    .aspectRatio(aspect, contentMode: .fit)
                    .overlay { if model.showFocusMap, let focusMap { FocusOverlay(map: focusMap) } }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 280)
                    .onTapGesture { model.openViewer(.single) }
                    .help("Click or press Space for full screen, Z for 100%, F for the focus map")
                    .task(id: "\(item.id)#\(model.showFocusMap)") {
                        focusMap = model.showFocusMap ? await ImageCache.shared.focusMap(for: item.photo) : nil
                    }

                header
                folderButtons
                if let score = item.score { signals(score) }
                reasons
                if model.groupOfSelection.count > 1 { group }
                if let analysis = item.analysis, !analysis.subjectFaces.isEmpty { faces(analysis) }
            }
            .padding(14)
        }
        .background(.background)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.photo.name).font(.headline).lineLimit(1).truncationMode(.middle)
                if let date = item.analysis?.captureDate {
                    Text(date, format: .dateTime.year().month().day().hour().minute().second())
                        .font(.caption).foregroundStyle(.secondary)
                        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                }
            }
            Spacer()
            Button { model.revealOriginal(item) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Show original in Finder")
        }
    }

    private var folderButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                folderButton(.picks, key: "P")
                folderButton(.moments, key: "M")
                folderButton(.review, key: "R")
                folderButton(.trash, key: "X")
            }
            if item.isManual {
                HStack {
                    Label("Placed by you", systemImage: "hand.point.up.left.fill").font(.caption)
                    Spacer()
                    Button("Back to automatic (U)") { model.moveSelection(to: nil) }
                        .buttonStyle(.link).font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private func folderButton(_ folder: Folder, key: String) -> some View {
        Button { model.moveSelection(to: folder) } label: {
            VStack(spacing: 1) {
                Text(folder.rawValue).font(.caption.weight(.medium))
                Text(key).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(item.folder == folder ? .accentColor : nil)
        .disabled(item.folder == folder)
    }

    private func signals(_ s: PhotoScore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Quality").font(.headline)
                Spacer()
                Text("\(Int((s.quality * 100).rounded()))").font(.title2.weight(.semibold).monospacedDigit())
            }
            SignalBar(label: "Sharpness", value: s.sharpness, help: item.analysis.map { $0.subjectFaces.isEmpty ? "Measured on the subject" : "Measured on the eyes" })
            SignalBar(label: "Exposure", value: s.exposure, help: item.analysis.map {
                "Blown highlights \(percent($0.exposure.highlightClip)), crushed shadows \(percent($0.exposure.shadowClip))"
            })
            if let a = s.aesthetics { SignalBar(label: "Aesthetics", value: a, help: "Apple Vision aesthetics score") }
            if let f = s.face { SignalBar(label: "Face quality", value: f, help: "Used to rank similar shots of the same people") }
        }
    }

    @ViewBuilder private var reasons: some View {
        let lines = (item.isManual ? ["You placed this in \(item.folder.rawValue)"] : []) + (item.decision?.reasons ?? [])
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Why").font(.headline)
                ForEach(lines, id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle").font(.callout)
                        .labelStyle(BulletLabelStyle())
                }
            }
        }
    }

    private func faces(_ analysis: PhotoAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Faces").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(analysis.subjectFaces.enumerated()), id: \.offset) { _, face in
                        FaceCrop(photo: item.photo, face: face)
                    }
                }
            }
        }
    }

    private var group: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Similar shots").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.groupOfSelection) { other in
                        VStack(spacing: 2) {
                            PhotoImage(photo: other.photo, size: 480)
                                .frame(width: 84, height: 60).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(other.id == item.id ? Color.accentColor : .clear, lineWidth: 2))
                            Text(other.folder.rawValue).font(.caption2).foregroundStyle(.secondary)
                        }
                        .onTapGesture {
                            model.select(tab: other.folder)
                            model.selection = other.id
                        }
                    }
                }
            }
        }
    }

    private func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
}

struct SignalBar: View {
    let label: String
    let value: Double
    var help: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.callout).frame(width: 92, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: geo.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 6)
            Text("\(Int((value * 100).rounded()))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
        .help(help ?? "")
    }

    private var color: Color { value >= 0.7 ? .green : value >= 0.4 ? .yellow : .red }
}

struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            configuration.title
        }
    }
}

struct FaceCrop: View {
    let photo: Photo
    let face: PhotoAnalysis.Face
    @State private var crop: CGImage?

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let crop { Image(decorative: crop, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                else { Rectangle().fill(.quaternary) }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: 2))
            HStack(spacing: 3) {
                if face.smiling == true { Image(systemName: "face.smiling").help("Smiling") }
                if face.eyesClosed == true { Image(systemName: "eye.slash").help("Eyes closed") }
                if let q = face.quality { Text("\(Int((q * 100).rounded()))").monospacedDigit().help("Face quality") }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .task(id: photo.decodeURL.path) {
            guard let image = await ImageCache.shared.image(for: photo, size: 1600) else { return }
            let r = face.rect
            let pad = 0.25
            let rect = CGRect(
                x: (r.x - r.width * pad) * Double(image.width), y: (r.y - r.height * pad) * Double(image.height),
                width: r.width * (1 + 2 * pad) * Double(image.width), height: r.height * (1 + 2 * pad) * Double(image.height)
            ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            crop = image.cropping(to: rect.integral)
        }
    }

    private var border: Color {
        if face.eyesClosed == true { return .red }
        if face.smiling == true { return .green }
        return .clear
    }
}
