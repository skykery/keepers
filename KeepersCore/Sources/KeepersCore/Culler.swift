import Foundation

public enum Folder: String, CaseIterable, Codable, Identifiable, Sendable {
    case picks = "Top Picks"
    case moments = "Moments"
    case review = "Review"
    case trash = "Trash"

    public var id: String { rawValue }
}

public enum Preset: String, CaseIterable, Codable, Identifiable, Sendable {
    case strict, balanced, lenient

    public var id: String { rawValue }

    /// Share of the usable (non-trashed) photos that go to Top Picks.
    public var pickFraction: Double {
        switch self {
        case .strict: return 0.05
        case .balanced: return 0.15
        case .lenient: return 0.25
        }
    }

    /// Frames of a group kept for review; lower-ranked ones are duplicates
    /// and go to Trash.
    public var keepPerGroup: Int {
        switch self {
        case .strict: return 2
        case .balanced: return 3
        case .lenient: return 5
        }
    }

    /// A frame scoring this far below its group's best goes to Trash, even
    /// within `keepPerGroup`.
    public var duplicateGap: Double {
        switch self {
        case .strict: return 0.03
        case .balanced: return 0.05
        case .lenient: return 0.08
        }
    }

    /// Floor below which nothing is a pick, however few photos qualify.
    public var minPickQuality: Double {
        switch self {
        case .strict: return 0.50
        case .balanced: return 0.42
        case .lenient: return 0.35
        }
    }

    public var gate: GateThresholds {
        switch self {
        case .strict: return GateThresholds(minSharpness: 0.30)
        case .balanced: return GateThresholds(minSharpness: 0.20)
        case .lenient: return GateThresholds(minSharpness: 0.12)
        }
    }

    public var title: String { rawValue.capitalized }

    public var summary: String {
        "Top \(Int(pickFraction * 100))% of usable shots"
    }
}

public struct Decision: Codable, Hashable, Sendable {
    public var folder: Folder
    public var reasons: [String]
    /// Index into `CullResult.groups`.
    public var group: Int
    /// 1 = best in its group.
    public var rankInGroup: Int
    /// Photos in the group; 1 for a lone shot or a rejected one.
    public var groupSize: Int
}

public struct CullResult {
    public var scores: [String: PhotoScore]
    public var decisions: [String: Decision]
    /// Photo names per group, best first.
    public var groups: [[String]]
}

/// Decides a folder for each photo.
///
/// 1. Hard gate: clear technical failures go to Trash.
/// 2. Group bursts; within a group, rank by quality. Only a group's best
///    frame can be a Top Pick, so ten frames of one moment yield one pick.
/// 3. Top Picks: the best group leaders, up to the preset's share of all
///    usable photos, above a quality floor, with no flaws (eyes closed…).
/// 4. Moments: the best-expression frame of groups that didn't get a pick,
///    when the main subject is smiling with eyes open. Technical quality only
///    has to pass the gate: a great expression can be a little soft.
/// 5. Weaker duplicates go to Trash: frames that score below their group's
///    best and either rank beyond the preset's `keepPerGroup` or trail the
///    best by `duplicateGap` or more.
/// 6. Everything else goes to Review, with its rank in its group.
public enum Culler {
    public static func cull(_ analyses: [String: PhotoAnalysis], preset: Preset,
                            weights: ScoringWeights = .init(),
                            grouper: BurstGrouper = .init()) -> CullResult {
        let gate = preset.gate
        let scores = analyses.mapValues { Scorer.score($0, weights: weights, gate: gate) }

        let usable = analyses.keys.filter { scores[$0]?.rejection == nil }
        let byDate = grouper.group(usable.map {
            BurstGrouper.Item(id: $0, date: analyses[$0]!.captureDate, print: analyses[$0]!.featurePrint)
        })
        func rankKey(_ name: String) -> Double {
            let s = scores[name]!
            return s.quality + (s.face ?? 0) * weights.faceInGroup
        }
        let groups = byDate.map { ids in
            ids.sorted { (rankKey($0), $1) > (rankKey($1), $0) }
        }

        var decisions: [String: Decision] = [:]
        for (name, score) in scores {
            if let rejection = score.rejection {
                decisions[name] = Decision(folder: .trash, reasons: [rejection], group: -1, rankInGroup: 1, groupSize: 1)
            }
        }

        // Top Picks.
        let pickBudget = max(1, Int((Double(usable.count) * preset.pickFraction).rounded()))
        let leaders = groups.indices
            .filter { scores[groups[$0][0]]!.flaws.isEmpty }
            .sorted { scores[groups[$0][0]]!.quality > scores[groups[$1][0]]!.quality }
        var pickedGroups = Set<Int>()
        for g in leaders.prefix(pickBudget) where scores[groups[g][0]]!.quality >= preset.minPickQuality {
            pickedGroups.insert(g)
        }

        // Moments.
        var momentByGroup: [Int: String] = [:]
        for (g, ids) in groups.enumerated() where !pickedGroups.contains(g) {
            let candidates = ids.filter { isMoment(analyses[$0]!) }
            if let best = candidates.max(by: { (scores[$0]!.face ?? 0) < (scores[$1]!.face ?? 0) }) {
                momentByGroup[g] = best
            }
        }
        let momentBudget = pickBudget
        let moments = Set(momentByGroup.values.sorted { scores[$0]!.quality > scores[$1]!.quality }.prefix(momentBudget))

        for (g, ids) in groups.enumerated() {
            for (i, name) in ids.enumerated() {
                let s = scores[name]!
                var reasons = s.flaws
                let folder: Folder
                if i == 0, pickedGroups.contains(g) {
                    folder = .picks
                    reasons.insert(ids.count > 1 ? "Best of \(ids.count) similar shots" : "Among the strongest shots", at: 0)
                } else if moments.contains(name) {
                    folder = .moments
                    reasons.insert("Great expression", at: 0)
                } else if i > 0, s.quality < scores[ids[0]]!.quality,
                          i >= preset.keepPerGroup || scores[ids[0]]!.quality - s.quality >= preset.duplicateGap {
                    // Only frames that also score lower than the best: a frame
                    // ranked lower on face quality alone is not "weaker".
                    folder = .trash
                    reasons.insert("Weaker duplicate: #\(i + 1) of \(ids.count) similar shots", at: 0)
                } else {
                    folder = .review
                    if ids.count > 1 {
                        reasons.append(i == 0 ? "Best of \(ids.count) similar shots" : "#\(i + 1) of \(ids.count) similar shots")
                    }
                    if i == 0, s.flaws.isEmpty, !pickedGroups.contains(g) {
                        reasons.append(s.quality < preset.minPickQuality ? "Below the quality bar for a pick"
                                       : "Good, but outranked by other shots")
                    }
                }
                decisions[name] = Decision(folder: folder, reasons: reasons, group: g, rankInGroup: i + 1, groupSize: ids.count)
            }
        }
        return CullResult(scores: scores, decisions: decisions, groups: groups)
    }

    static func isMoment(_ a: PhotoAnalysis) -> Bool {
        guard let primary = a.primaryFace, primary.smiling == true, primary.eyesClosed != true else { return false }
        return (primary.quality ?? 0) >= 0.45
    }
}
