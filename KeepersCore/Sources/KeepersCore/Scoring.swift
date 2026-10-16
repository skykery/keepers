import Foundation

/// How a photo scores, with each signal kept so the UI can show its work.
public struct PhotoScore: Codable, Hashable, Sendable {
    /// Weighted quality, 0...1, comparable across the whole shoot.
    public var quality: Double
    public var sharpness: Double
    public var exposure: Double
    public var aesthetics: Double?
    /// Mean Vision face capture quality of the subjects. Vision means it for
    /// comparing shots of the same person, so it only ranks within a group.
    public var face: Double?
    /// Hard failure that sends the photo to Trash regardless of rank.
    public var rejection: String?
    /// Problems that keep the photo out of Top Picks but don't trash it.
    public var flaws: [String]
}

public struct ScoringWeights: Codable, Hashable, Sendable {
    public var sharpness = 0.35
    public var exposure = 0.20
    public var aesthetics = 0.45
    /// Added to quality (times face quality) when ranking frames of one group.
    public var faceInGroup = 0.5
    public init() {}
}

/// Thresholds for the hard gate. Only clear technical failures go to Trash;
/// everything else is decided by rank.
public struct GateThresholds: Codable, Hashable, Sendable {
    /// Below this subject sharpness (and with nothing sharp anywhere) the photo is a miss.
    public var minSharpness: Double
    public var maxHighlightClip = 0.25
    public var maxShadowClip = 0.60
}

public enum Scorer {
    public static func score(_ a: PhotoAnalysis, weights: ScoringWeights = .init(),
                             gate: GateThresholds) -> PhotoScore {
        let sharpness = Self.sharpness(a.subjectFocus)
        let exposure = exposureScore(a.exposure)

        var face: Double?
        let subjects = a.subjectFaces
        if !subjects.isEmpty {
            let qualities = subjects.compactMap(\.quality)
            face = qualities.isEmpty ? nil : qualities.reduce(0, +) / Double(qualities.count)
        }

        var parts: [(value: Double, weight: Double)] = [
            (sharpness, weights.sharpness),
            (exposure, weights.exposure),
        ]
        if let aesthetics = a.aesthetics { parts.append((aesthetics, weights.aesthetics)) }
        let total = parts.reduce(0) { $0 + $1.weight }
        var quality = parts.reduce(0) { $0 + $1.value * $1.weight } / total

        var flaws: [String] = []
        if let primary = a.primaryFace, primary.eyesClosed == true {
            flaws.append("Eyes closed")
            quality *= 0.7
        }
        let blinking = subjects.filter { $0.eyesClosed == true }.count
        if subjects.count > 1, blinking > 0, a.primaryFace?.eyesClosed != true {
            flaws.append(blinking == 1 ? "Someone is blinking" : "\(blinking) people are blinking")
            quality *= 0.85
        }

        return PhotoScore(quality: quality, sharpness: sharpness, exposure: exposure,
                          aesthetics: a.aesthetics, face: face,
                          rejection: rejection(a, gate: gate), flaws: flaws)
    }

    /// 1 for a well-exposed subject with little clipping, falling toward 0 as
    /// highlights blow, shadows block up, or the subject sits far from mid-tone.
    static func exposureScore(_ e: PixelMetrics.Exposure) -> Double {
        let highlightPenalty = ramp(e.highlightClip, from: 0.02, to: 0.20)
        let shadowPenalty = ramp(e.shadowClip, from: 0.10, to: 0.50)
        let offMidtone = e.subjectLuminance < 0.25 ? 0.25 - e.subjectLuminance
            : e.subjectLuminance > 0.75 ? e.subjectLuminance - 0.75 : 0
        let midtonePenalty = min(offMidtone / 0.25, 1) * 0.5
        return max(0, 1 - max(highlightPenalty, shadowPenalty)) * (1 - midtonePenalty)
    }

    static func rejection(_ a: PhotoAnalysis, gate: GateThresholds) -> String? {
        // Vision's `isUtility` is not used: it flags plenty of real
        // still-life photos as documents.
        // Intentional soft-subject shots usually still have something sharp.
        if sharpness(a.subjectFocus) < gate.minSharpness, sharpness(a.globalFocus) < gate.minSharpness * 1.5 {
            return "Out of focus"
        }
        if a.exposure.highlightClip > gate.maxHighlightClip { return "Blown highlights" }
        if a.exposure.shadowClip > gate.maxShadowClip { return "Severely underexposed" }
        return nil
    }

    /// Focus energy scale: sharpness is 0.63 at this energy and ~0.95 at 3x.
    /// Calibrated on 2048 px previews: missed focus and motion blur sit
    /// under ~5, in-focus eyes 20–45, busy textures (branches) 100+.
    public static let focusScale = 18.0

    /// Maps focus energy to 0...1. Saturates on purpose: past "in focus",
    /// more texture is not a better photo.
    public static func sharpness(_ energy: Double) -> Double {
        1 - exp(-energy / focusScale)
    }

    /// 0 below `from`, 1 above `to`, linear between.
    static func ramp(_ x: Double, from: Double, to: Double) -> Double {
        min(max((x - from) / (to - from), 0), 1)
    }
}
