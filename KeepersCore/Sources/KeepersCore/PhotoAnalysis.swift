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
