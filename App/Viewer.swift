import AppKit
import KeepersCore
import SwiftUI

// MARK: - Zoomable image

enum ZoomMode: Equatable {
    case fit
    /// 1 image pixel per screen pixel of the original, centered on a point
    /// in normalized top-left coordinates.
    case actual(CGPoint)
}

/// Keeps several zoomable images at the same zoom and position (compare view).
final class ZoomSync {
    fileprivate var views: [WeakScrollView] = []
    fileprivate var syncing = false

    fileprivate func register(_ view: NSScrollView) {
        views.removeAll { $0.view == nil || $0.view === view }
        views.append(WeakScrollView(view: view))
    }

    /// Mirrors `source`'s magnification and relative visible center to the others.
    fileprivate func propagate(from source: NSScrollView) {
        guard !syncing, let doc = source.documentView, doc.bounds.width > 0 else { return }
        syncing = true
        defer { syncing = false }
        let visible = source.contentView.documentVisibleRect
        let center = CGPoint(x: visible.midX / doc.bounds.width, y: visible.midY / doc.bounds.height)
        for other in views.compactMap(\.view) where other !== source {
            guard let otherDoc = other.documentView else { continue }
            other.magnification = source.magnification * (doc.bounds.width / max(otherDoc.bounds.width, 1))
            let size = other.contentView.bounds.size
            let point = CGPoint(x: center.x * otherDoc.bounds.width - size.width / 2,
                                y: center.y * otherDoc.bounds.height - size.height / 2)
            other.contentView.scroll(to: other.contentView.constrainBoundsRect(CGRect(origin: point, size: size)).origin)
            other.reflectScrolledClipView(other.contentView)
        }
    }
}

fileprivate struct WeakScrollView { weak var view: NSScrollView? }

/// An image in an NSScrollView: pinch and scroll to zoom and pan, with
/// "fit" and "100%" modes and an optional focus-map overlay.
struct ZoomableImage: NSViewRepresentable {
    let image: CGImage?
    /// The original's pixel size; 100% means one original pixel per screen pixel.
    let nativeSize: CGSize
    let mode: ZoomMode
    var focusMap: PixelMetrics.FocusMap?
    var sync: ZoomSync?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 8
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .black
        scroll.contentView = CenteringClipView()
        scroll.contentView.drawsBackground = false
        let doc = ImageDocumentView()
        scroll.documentView = doc
        context.coordinator.scrollView = scroll
        // Sync only what the user does (scroll, pinch); programmatic zooms
        // during layout would otherwise bounce between panes.
        for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveMagnifyNotification] {
            NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.userMoved),
                                                   name: name, object: scroll)
        }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.frameChanged),
                                               name: NSView.frameDidChangeNotification, object: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.sync = sync
        if let sync { sync.register(scroll) }
        guard let doc = scroll.documentView as? ImageDocumentView else { return }
        let scale = scroll.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: max(nativeSize.width, 1) / scale, height: max(nativeSize.height, 1) / scale)
        let sizeChanged = doc.frame.size != size
        if sizeChanged { doc.frame = CGRect(origin: .zero, size: size) }
        doc.setImage(image)
        doc.setFocusMap(focusMap)
        if sizeChanged || c.appliedMode != mode {
            c.mode = mode
            c.apply()
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        var sync: ZoomSync?
        var mode: ZoomMode = .fit
        var appliedMode: ZoomMode?
        private var applying = false

        func apply() {
            guard let scroll = scrollView, let doc = scroll.documentView, doc.bounds.width > 0,
                  scroll.contentView.bounds.width > 0 else { return }
            applying = true
            defer { applying = false; appliedMode = mode }
            switch mode {
            case .fit:
                scroll.magnify(toFit: doc.bounds)
            case .actual(let p):
                let point = CGPoint(x: p.x * doc.bounds.width, y: p.y * doc.bounds.height)
                scroll.setMagnification(1, centeredAt: point)
            }
        }

        @objc func userMoved() {
            guard !applying, let scroll = scrollView else { return }
            sync?.propagate(from: scroll)
        }

        @objc func frameChanged() {
            if mode == .fit { apply() }
        }
    }
}

/// Centers the image when it's smaller than the view (NSScrollView pins it
/// to the corner otherwise).
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

/// Draws the image (and focus map) with layers; flipped so normalized
/// top-left coordinates map directly.
final class ImageDocumentView: NSView {
    private let imageLayer = CALayer()
    private let mapLayer = CALayer()
    private var image: CGImage?
    private var mapIdentity: ObjectIdentifier?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The last row and column of tiles are partial; keep them on the image.
        layer?.masksToBounds = true
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(mapLayer)
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        mapLayer.contentsGravity = .resize
        mapLayer.magnificationFilter = .nearest
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        layoutMap()
        CATransaction.commit()
    }

    func setImage(_ image: CGImage?) {
        guard image !== self.image else { return }
        self.image = image
        imageLayer.contents = image
    }

    private var map: PixelMetrics.FocusMap?

    func setFocusMap(_ map: PixelMetrics.FocusMap?) {
        if map == nil, self.map == nil { return }
        if let map, let old = self.map, map.energies == old.energies { return }
        self.map = map
        mapLayer.contents = map.flatMap(FocusOverlayImage.make)
        mapLayer.isHidden = map == nil
        needsLayout = true
    }

    private func layoutMap() {
        guard let map, map.imageWidth > 0, map.imageHeight > 0 else { return }
        // Tiles start 1 px in and cover columns × tile pixels of the measured image.
        let w = bounds.width / CGFloat(map.imageWidth), h = bounds.height / CGFloat(map.imageHeight)
        mapLayer.frame = CGRect(x: w, y: h, width: CGFloat(map.columns * map.tile) * w, height: CGFloat(map.rows * map.tile) * h)
    }
}

enum FocusOverlayImage {
    /// One pixel per tile, green where sharp, transparent where soft.
    static func make(_ map: PixelMetrics.FocusMap) -> CGImage? {
        guard map.columns > 0, map.rows > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: map.columns * map.rows * 4)
        for row in 0..<map.rows {
            for column in 0..<map.columns {
                let s = map.sharpness(column: column, row: row)
                let alpha = s > 0.5 ? (s - 0.5) * 2 * 0.6 : 0
                let i = (row * map.columns + column) * 4
                // Premultiplied RGBA.
                pixels[i] = UInt8(40 * alpha); pixels[i + 1] = UInt8(255 * alpha)
                pixels[i + 2] = UInt8(90 * alpha); pixels[i + 3] = UInt8(255 * alpha)
            }
        }
        let data = Data(pixels) as CFData
        return CGImage(width: map.columns, height: map.rows, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: map.columns * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - A photo in the viewer

/// Loads the largest quick image, and the full-resolution original when
/// zoomed to 100% and the quick one is smaller.
struct ViewerPane: View {
    @EnvironmentObject private var model: AppModel
    let item: PhotoItem
    let mode: ZoomMode
    var sync: ZoomSync?

    @State private var large: ImageDecoder.LargeImage?
    @State private var map: PixelMetrics.FocusMap?
    @State private var loadingFull = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZoomableImage(image: large?.image, nativeSize: large?.nativeSize ?? nativeGuess,
                          mode: mode, focusMap: model.showFocusMap ? map : nil, sync: sync)
            if large == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if loadingFull {
                Label("Loading full resolution…", systemImage: "hourglass")
                    .font(.caption).padding(6)
                    .background(.ultraThinMaterial, in: Capsule()).padding(8)
            }
        }
        .task(id: item.id) {
            large = ImageCache.shared.cachedLarge(item.photo, full: false)
            if large == nil { large = await ImageCache.shared.largeImage(for: item.photo, full: false) }
        }
        .task(id: "\(item.id)#\(isActual)") {
            guard isActual, let current = large, !current.isFullResolution else { return }
            loadingFull = true
            if let full = await ImageCache.shared.largeImage(for: item.photo, full: true), !Task.isCancelled {
                large = full
            }
            loadingFull = false
        }
        .task(id: "\(item.id)#map#\(model.showFocusMap)") {
            guard model.showFocusMap else { return }
            map = await ImageCache.shared.focusMap(for: item.photo)
        }
    }

    private var isActual: Bool { if case .actual = mode { return true } else { return false } }

    private var nativeGuess: CGSize {
        CGSize(width: item.analysis?.pixelWidth ?? 3, height: item.analysis?.pixelHeight ?? 2)
    }
}

extension PhotoItem {
    /// Where to center a 100% view: the main face's eyes, else the subject.
    var focusPoint: CGPoint {
        guard let a = analysis else { return CGPoint(x: 0.5, y: 0.5) }
        let r = a.primaryFace?.rect.eyeBand ?? a.subject
        return CGPoint(x: r.midX, y: r.midY)
    }
}

// MARK: - Full-screen viewer

struct ViewerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            if let item = model.selectedItem {
                ViewerPane(item: item, mode: model.zoomActual ? .actual(item.focusPoint) : .fit)
                    .id(item.id)
                hud(item)
            } else {
                Text("Nothing left in \(model.tab.rawValue)").foregroundStyle(.secondary)
            }
        }
    }

    private func hud(_ item: PhotoItem) -> some View {
        HStack(spacing: 14) {
            Text(item.photo.name).font(.callout.weight(.semibold))
            Text(item.folder.rawValue).foregroundStyle(.secondary)
            if let d = item.decision, d.groupSize > 1 { Text("\(d.rankInGroup) of \(d.groupSize)").foregroundStyle(.secondary) }
            if let q = item.score?.quality { Text("Quality \(Int((q * 100).rounded()))").foregroundStyle(.secondary) }
            Spacer()
            Text(model.zoomActual ? "100%" : "Fit").monospacedDigit()
            Text("Z zoom · F focus · C compare · P M R X move · Esc close").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Compare

struct CompareView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sync = ZoomSync()

    var body: some View {
        let frames = model.compareItems
        let focused = frames.first { $0.id == model.selection } ?? frames.first
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(frames) { item in
                    VStack(spacing: 0) {
                        // Each frame zooms on its own subject: in a burst the subject moves.
                        ViewerPane(item: item, mode: model.zoomActual ? .actual(item.focusPoint) : .fit, sync: sync)
                            .overlay(Rectangle().strokeBorder(item.id == focused?.id ? Color.accentColor : .clear, lineWidth: 3))
                            .onTapGesture { model.selection = item.id }
                        label(item, focused: item.id == focused?.id)
                    }
                }
            }
            HStack {
                Text("Comparing \(frames.count) similar shots").font(.caption.weight(.semibold))
                Spacer()
                Text("← → choose · Z zoom (linked) · F focus · P M R X move · Esc close")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
        .background(Color.black)
    }

    private func label(_ item: PhotoItem, focused: Bool) -> some View {
        HStack(spacing: 8) {
            Text(item.decision.map { "#\($0.rankInGroup)" } ?? "").monospacedDigit()
            Text(item.photo.name).lineLimit(1)
            Spacer()
            Text(item.folder.rawValue).foregroundStyle(item.isManual ? .primary : .secondary)
            if let q = item.score?.quality { Text("\(Int((q * 100).rounded()))").monospacedDigit() }
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(focused ? Color.accentColor.opacity(0.35) : Color.black.opacity(0.6))
        .foregroundStyle(.white)
    }
}

// MARK: - Focus overlay for the sidebar image

struct FocusOverlay: View {
    let map: PixelMetrics.FocusMap

    var body: some View {
        Canvas { context, size in
            let w = size.width / CGFloat(map.imageWidth), h = size.height / CGFloat(map.imageHeight)
            for row in 0..<map.rows {
                for column in 0..<map.columns {
                    let s = map.sharpness(column: column, row: row)
                    guard s > 0.5 else { continue }
                    let rect = CGRect(x: CGFloat(1 + column * map.tile) * w, y: CGFloat(1 + row * map.tile) * h,
                                      width: CGFloat(map.tile) * w, height: CGFloat(map.tile) * h)
                    context.fill(Path(rect.intersection(CGRect(origin: .zero, size: size))), with: .color(Color(red: 0.15, green: 1, blue: 0.35).opacity((s - 0.5) * 2 * 0.6)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
