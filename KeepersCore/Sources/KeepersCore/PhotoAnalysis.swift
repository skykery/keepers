import Foundation

/// Everything measured about one photo. Pure data: scoring and folder
/// decisions are computed from this, so changing a preset or a weight never
/// requires re-analysis.
public struct PhotoAnalysis: Codable, Hashable, Sendable {
    public struct Face: Codable, Hashable, Sendable {
        public var rect: NormRect
        /// Vision's face capture quality (blur, lighting, pose, expression), 0...1.
        public var quality: Double?
        /// Focus energy of the eye band (see `PixelMetrics.focusEnergy`).
        public var focus: Double
        public var smiling: Bool?
        public var eyesClosed: Bool?
        /// Mouth geometry from Vision landmarks; `Scorer.smile` turns it into
        /// a 0...1 smile size. Nil when landmarks weren't found.
        public var mouth: MouthShape?
        /// Large enough to be what the photo is about, rather than a bystander.
        public var isSubject: Bool
    }

    public var captureDate: Date
    public var pixelWidth: Int
    public var pixelHeight: Int

    /// Region the photo is about: faces, else the salient object, else the center.
    public var subject: NormRect
    /// Focus energy of the subject (eye bands when there are faces).
    public var subjectFocus: Double
    /// Focus energy of the sharpest area anywhere in the frame.
    public var globalFocus: Double
    public var exposure: PixelMetrics.Exposure

    /// 0...1, or nil when no aesthetics model is available on this macOS.
    public var aesthetics: Double?
    /// Screenshots, receipts, documents.
    public var isUtility: Bool

    public var faces: [Face]
    public var featurePrint: FeaturePrint?
    /// Focus energy of the eye band (or subject) measured on the largest
    /// available image without downscaling. Only meaningful compared with
    /// other frames of the same burst; measured for each group's top frames.
    public var detailFocus: Double?
    /// Exposure compensation and camera focus point.
    public var metadata: CaptureMetadata?
    /// Cats and dogs Vision found (it recognizes only those two).
    public var animals: [NormRect]?
    /// Movement from the previous frame when it overlaps like a panorama
    /// sequence (see `CullSession.linkPanoramas`).
    public var panLink: PanLink?

    /// Which version of the analysis produced this. Older ones are redone.
    public var revision: Int?
    /// 1: 2.0–2.2. 2: smiles, pets, focus point, exposure bias.
    public static let currentRevision = 2

    public var subjectFaces: [Face] { faces.filter(\.isSubject) }

    /// The face the photo is most about: big and near the center.
    public var primaryFace: Face? {
        subjectFaces.max { prominence($0) < prominence($1) }
    }

    private func prominence(_ f: Face) -> Double {
        let off = hypot(f.rect.midX - 0.5, f.rect.midY - 0.5)
        return f.rect.area * (1.2 - off)
    }
}

/// The previous frame of a possible panorama, and how far the view moved
/// from it (fractions of the frame; + is right / down).
public struct PanLink: Codable, Hashable, Sendable {
    public var previous: String
    public var dx: Double
    public var dy: Double
    public init(previous: String, dx: Double, dy: Double) { self.previous = previous; self.dx = dx; self.dy = dy }
}

/// Mouth geometry in a face-aligned frame (eye line horizontal), measured
/// relative to the face so it doesn't depend on size or head tilt.
public struct MouthShape: Codable, Hashable, Sendable {
    /// Mouth width / distance between the eyes. Wider in a smile.
    public var widthRatio: Double
    /// How far the mouth corners sit above the lips' midline, as a fraction of
    /// mouth width. Positive in a smile, negative in a frown.
    public var cornerLift: Double
    /// Gap between the inner lips / mouth width. Large when laughing.
    public var openness: Double

    public init(widthRatio: Double, cornerLift: Double, openness: Double) {
        self.widthRatio = widthRatio; self.cornerLift = cornerLift; self.openness = openness
    }

    /// From landmark points in image coordinates (y up, as Vision gives them).
    public init?(leftEye: [CGPoint], rightEye: [CGPoint], outerLips: [CGPoint], innerLips: [CGPoint]) {
        guard !leftEye.isEmpty, !rightEye.isEmpty, outerLips.count >= 4 else { return nil }
        func centroid(_ p: [CGPoint]) -> CGPoint {
            CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
        }
        // Order the eyes by x so the axis points right whatever Vision calls "left".
        let e = [centroid(leftEye), centroid(rightEye)].sorted { $0.x < $1.x }
        let dx = e[1].x - e[0].x, dy = e[1].y - e[0].y
        let eyeDistance = hypot(dx, dy)
        guard eyeDistance > 0 else { return nil }
        let angle = atan2(dy, dx)
        let cosA = cos(-angle), sinA = sin(-angle)
        func align(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * cosA - p.y * sinA, y: p.x * sinA + p.y * cosA)
        }
        let outer = outerLips.map(align), inner = innerLips.map(align)
        guard let left = outer.min(by: { $0.x < $1.x }), let right = outer.max(by: { $0.x < $1.x }) else { return nil }
        let width = right.x - left.x
        guard width > 0 else { return nil }
        // The lips' midline: halfway between top and bottom near the center.
        let midX = (left.x + right.x) / 2
        let central = outer.filter { abs($0.x - midX) <= width * 0.2 }
        guard let top = central.map(\.y).max(), let bottom = central.map(\.y).min() else { return nil }
        let midline = (top + bottom) / 2
        let innerCentral = inner.filter { abs($0.x - midX) <= width * 0.2 }
        let gap = (innerCentral.map(\.y).max() ?? 0) - (innerCentral.map(\.y).min() ?? 0)

        widthRatio = Double(width / eyeDistance)
        cornerLift = Double(((left.y + right.y) / 2 - midline) / width)
        openness = Double(max(0, gap) / width)
    }
}

/// Vision image feature print, kept as floats so distances are computed the
/// same way regardless of macOS version.
public struct FeaturePrint: Codable, Hashable, Sendable {
    public var revision: Int
    public var vector: [Float]

    public init(revision: Int, vector: [Float]) {
        self.revision = revision
        self.vector = vector
    }

    // Stored as raw float bytes (base64 in JSON): about a third the size of a
    // number array, which dominates the cache file. Caches from 2.0–2.1 used
    // the number array and still decode.
    private enum CodingKeys: String, CodingKey { case revision, data, vector }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(Int.self, forKey: .revision)
        if let data = try c.decodeIfPresent(Data.self, forKey: .data) {
            vector = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        } else {
            vector = try c.decode([Float].self, forKey: .vector)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(revision, forKey: .revision)
        try c.encode(vector.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .data)
    }

    /// Cosine distance, 0 (identical) ... 2.
    public func distance(to other: FeaturePrint) -> Double? {
        guard revision == other.revision, vector.count == other.vector.count, !vector.isEmpty else { return nil }
        var dot: Float = 0, a: Float = 0, b: Float = 0
        for i in vector.indices {
            dot += vector[i] * other.vector[i]
            a += vector[i] * vector[i]
            b += other.vector[i] * other.vector[i]
        }
        guard a > 0, b > 0 else { return nil }
        return Double(1 - dot / (a.squareRoot() * b.squareRoot()))
    }
}
