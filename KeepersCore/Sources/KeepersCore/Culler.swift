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

    public var settings: CullSettings {
        CullSettings(pickFraction: pickFraction, minPickQuality: minPickQuality, minSharpness: gate.minSharpness,
                     keepPerGroup: keepPerGroup, duplicateGap: duplicateGap)
    }

    public var summary: String {
        "Top \(Int(pickFraction * 100))% of usable shots"
    }
}

/// Everything that decides folders, beyond the analysis itself. Presets map
/// to these; a custom preset and learned weights change them.
public struct CullSettings: Codable, Hashable, Sendable {
    /// Share of the usable photos that go to Top Picks.
    public var pickFraction: Double
    /// Floor below which nothing is a pick.
    public var minPickQuality: Double
    /// Out-of-focus floor (sharpness, 0...1).
    public var minSharpness: Double
    /// Frames of a group kept for review; lower-ranked weaker ones go to Trash.
    public var keepPerGroup: Int
    /// A frame this far below its group's best goes to Trash.
    public var duplicateGap: Double
    public var weights = ScoringWeights()

    public init(pickFraction: Double, minPickQuality: Double, minSharpness: Double,
                keepPerGroup: Int, duplicateGap: Double, weights: ScoringWeights = ScoringWeights()) {
        self.pickFraction = pickFraction; self.minPickQuality = minPickQuality; self.minSharpness = minSharpness
        self.keepPerGroup = keepPerGroup; self.duplicateGap = duplicateGap; self.weights = weights
    }

    public var gate: GateThresholds { GateThresholds(minSharpness: minSharpness) }
}

/// Groups fixed by hand, in capture order: a photo that starts a new group,
/// joins the group of the photo before it, or stands alone (separated).
public struct GroupOverrides: Codable, Hashable, Sendable {
    public var breaks: Set<String> = []
    public var joins: Set<String> = []
    public var separated: Set<String> = []
    public init(breaks: Set<String> = [], joins: Set<String> = [], separated: Set<String> = []) {
        self.breaks = breaks; self.joins = joins; self.separated = separated
    }

    public func contains(_ name: String) -> Bool {
        breaks.contains(name) || joins.contains(name) || separated.contains(name)
    }

    // Older grouping.json files have no `separated`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        breaks = try c.decodeIfPresent(Set<String>.self, forKey: .breaks) ?? []
        joins = try c.decodeIfPresent(Set<String>.self, forKey: .joins) ?? []
        separated = try c.decodeIfPresent(Set<String>.self, forKey: .separated) ?? []
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
/// 4. Moments: per group, the frame with the biggest smile (main subject
///    smiling, eyes open). In a group whose best frame is a pick, only a
///    big smile clearly bigger than the pick's qualifies. Technical quality
///    only has to pass the gate: a great expression can be a little soft.
/// 5. Weaker duplicates go to Trash: frames that score below their group's
///    best and either rank beyond the preset's `keepPerGroup` or trail the
///    best by `duplicateGap` or more.
/// 6. Everything else goes to Review, with its rank in its group.
///
/// Sequences are kept whole: an exposure bracket follows its base (0 EV)
/// frame's folder and its frames never fail on exposure; a panorama
/// sequence goes to Review together and is never trashed.
public enum Culler {
    public static func cull(_ analyses: [String: PhotoAnalysis], preset: Preset,
                            weights: ScoringWeights = .init(), overrides: GroupOverrides = .init()) -> CullResult {
        var settings = preset.settings
        settings.weights = weights
        return cull(analyses, settings: settings, overrides: overrides)
    }

    public static func cull(_ analyses: [String: PhotoAnalysis], settings: CullSettings,
                            overrides: GroupOverrides = .init()) -> CullResult {
        let weights = settings.weights
        var grouper = BurstGrouper()
        grouper.breaks = overrides.breaks
        grouper.joins = overrides.joins
        grouper.separated = overrides.separated
        let gate = settings.gate
        let bracketSets = brackets(analyses)
        let inBracket = Set(bracketSets.flatMap { $0 })
        var scores: [String: PhotoScore] = [:]
        for (name, a) in analyses {
            scores[name] = Scorer.score(a, weights: weights, gate: gate, exposureExempt: inBracket.contains(name))
        }
        // A bracket is judged by its base frame (closest to 0 EV); the rest follow it.
        var bracketBase: [String: String] = [:]
        for set in bracketSets {
            let base = set.min { a, b in
                let ea = abs(analyses[a]!.metadata?.exposureBias ?? 0), eb = abs(analyses[b]!.metadata?.exposureBias ?? 0)
                return ea != eb ? ea < eb : scores[a]!.quality > scores[b]!.quality
            }!
            for name in set where name != base { bracketBase[name] = base }
        }
        let panoramaSets = panoramas(analyses).filter { set in set.allSatisfy { !inBracket.contains($0) } }
        let inPanorama = Set(panoramaSets.flatMap { $0 })

        let usable = analyses.keys.filter {
            scores[$0]?.rejection == nil && bracketBase[$0] == nil && !inPanorama.contains($0)
        }
        let byDate = grouper.group(usable.map {
            BurstGrouper.Item(id: $0, date: analyses[$0]!.captureDate, print: analyses[$0]!.featurePrint)
        })
        // Frames with a flaw (closed eyes…) rank after every flawless frame
        // of their group, whatever their other signals.
        func rankKey(_ name: String) -> Double {
            let s = scores[name]!
            // Fewer people blinking ranks higher among flawed frames too.
            return s.quality + (s.face ?? 0) * weights.faceInGroup - (s.flaws.isEmpty ? 0 : 10) - Double(s.blinking)
        }
        // Within a group, the full-detail focus check counts too, relative
        // to the group's sharpest measured frame.
        var detailLeaders = Set<String>()
        let groups: [[String]] = byDate.map { ids in
            let measured = ids.compactMap { analyses[$0]!.detailFocus }
            guard measured.count >= 2, let best = measured.max(), best > 0 else {
                return ids.sorted { (rankKey($0), $1) > (rankKey($1), $0) }
            }
            func key(_ n: String) -> Double {
                rankKey(n) + (analyses[n]!.detailFocus.map { $0 / best } ?? 0) * weights.detailInGroup
            }
            let sorted = ids.sorted { (key($0), $1) > (key($1), $0) }
            if analyses[sorted[0]]!.detailFocus == best { detailLeaders.insert(sorted[0]) }
            return sorted
        }

        var decisions: [String: Decision] = [:]
        for (name, score) in scores where bracketBase[name] == nil && !inPanorama.contains(name) {
            if let rejection = score.rejection {
                // A big smile is worth a look even when the frame failed.
                if (score.smile ?? 0) >= Scorer.bigSmile {
                    decisions[name] = Decision(folder: .review, reasons: ["Big smile: kept out of Trash", rejection],
                                               group: -1, rankInGroup: 1, groupSize: 1)
                } else {
                    decisions[name] = Decision(folder: .trash, reasons: [rejection], group: -1, rankInGroup: 1, groupSize: 1)
                }
            }
        }

        // Top Picks.
        let pickBudget = max(1, Int((Double(usable.count) * settings.pickFraction).rounded()))
        let leaders = groups.indices
            .filter { scores[groups[$0][0]]!.flaws.isEmpty }
            .sorted { scores[groups[$0][0]]!.quality > scores[groups[$1][0]]!.quality }
        var pickedGroups = Set<Int>()
        for g in leaders.prefix(pickBudget) where scores[groups[g][0]]!.quality >= settings.minPickQuality {
            pickedGroups.insert(g)
        }

        // Moments.
        var momentByGroup: [Int: String] = [:]
        for (g, ids) in groups.enumerated() {
            var candidates = ids.filter { isMoment(analyses[$0]!) }
            // In a group with a pick, a Moment must be a big smile that's
            // clearly bigger than the pick's.
            if pickedGroups.contains(g) {
                let pickSmile = scores[ids[0]]!.smile ?? 0
                candidates = candidates.filter {
                    $0 != ids[0] && (scores[$0]!.smile ?? 0) >= Scorer.bigSmile && (scores[$0]!.smile ?? 0) >= pickSmile + 0.2
                }
            }
            // The biggest smile; face quality breaks ties.
            func momentKey(_ n: String) -> Double { (scores[n]!.smile ?? 0) + (scores[n]!.face ?? 0) * 0.01 }
            if let best = candidates.max(by: { momentKey($0) < momentKey($1) }) {
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
                    reasons.insert((s.smile ?? 0) >= Scorer.bigSmile ? "Big smile" : "Great expression", at: 0)
                } else if i > 0, s.quality < scores[ids[0]]!.quality,
                          i >= settings.keepPerGroup || scores[ids[0]]!.quality - s.quality >= settings.duplicateGap {
                    // Only frames that also score lower than the best: a frame
                    // ranked lower on face quality alone is not "weaker".
                    if (s.smile ?? 0) >= Scorer.bigSmile {
                        folder = .review
                        reasons.insert("Big smile: kept out of Trash", at: 0)
                        reasons.append("#\(i + 1) of \(ids.count) similar shots")
                    } else {
                        folder = .trash
                        reasons.insert("Weaker duplicate: #\(i + 1) of \(ids.count) similar shots", at: 0)
                    }
                } else {
                    folder = .review
                    if ids.count > 1 {
                        reasons.append(i == 0 ? "Best of \(ids.count) similar shots" : "#\(i + 1) of \(ids.count) similar shots")
                    }
                    if i == 0, s.flaws.isEmpty, !pickedGroups.contains(g) {
                        reasons.append(s.quality < settings.minPickQuality ? "Below the quality bar for a pick"
                                       : "Good, but outranked by other shots")
                    }
                }
                if detailLeaders.contains(name), folder != .trash { reasons.append("Sharpest of its group at full resolution") }
                if s.blinking == 0, analyses[name]!.subjectFaces.count >= 2, ids.contains(where: { scores[$0]!.blinking > 0 }) {
                    reasons.append("Everyone's eyes open")
                }
                decisions[name] = Decision(folder: folder, reasons: reasons, group: g, rankInGroup: i + 1, groupSize: ids.count)
            }
        }

        var allGroups = groups

        // Brackets follow their base frame.
        for set in bracketSets {
            guard let base = set.first(where: { bracketBase[$0] == nil }), let baseDecision = decisions[base] else { continue }
            let label = "Exposure bracket: " + set.compactMap { analyses[$0]!.metadata?.exposureBias }.map(ev).joined(separator: ", ") + " EV"
            decisions[base]!.reasons.append(label)
            for name in set where name != base {
                decisions[name] = Decision(folder: baseDecision.folder, reasons: [label, "Kept with its bracket's base frame, \(base)"],
                                           group: -1, rankInGroup: 1, groupSize: 1)
            }
        }

        // Panoramas go to Review whole, as a group of their own.
        for set in panoramaSets {
            let g = allGroups.count
            allGroups.append(set)
            for (i, name) in set.enumerated() {
                decisions[name] = Decision(folder: .review, reasons: ["Panorama sequence: frame \(i + 1) of \(set.count)"],
                                           group: g, rankInGroup: i + 1, groupSize: set.count)
            }
        }

        for (name, s) in scores where !s.notes.isEmpty { decisions[name]?.reasons += s.notes }
        return CullResult(scores: scores, decisions: decisions, groups: allGroups)
    }

    /// `+2`, `0`, `−1.3`.
    static func ev(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        if r == 0 { return "0" }
        let text = r == r.rounded() ? String(Int(abs(r))) : String(format: "%.1f", abs(r))
        return (r > 0 ? "+" : "−") + text
    }

    /// Frames shot as an exposure bracket: consecutive frames at most 2 s
    /// apart whose exposure compensation changes each time, spanning at
    /// least 0.6 EV.
    static func brackets(_ analyses: [String: PhotoAnalysis]) -> [[String]] {
        let sorted = analyses.filter { $0.value.metadata?.exposureBias != nil }
            .sorted { ($0.value.captureDate, $0.key) < ($1.value.captureDate, $1.key) }
        var sets: [[String]] = []
        var run: [(String, PhotoAnalysis)] = []
        func flush() {
            let biases = run.map { $0.1.metadata!.exposureBias! }
            if run.count >= 2, let lo = biases.min(), let hi = biases.max(), hi - lo >= 0.6 { sets.append(run.map(\.0)) }
            run = []
        }
        for item in sorted {
            if let last = run.last,
               item.value.captureDate.timeIntervalSince(last.1.captureDate) <= 2,
               item.value.metadata!.exposureBias! != last.1.metadata!.exposureBias!,
               !run.contains(where: { $0.1.metadata!.exposureBias! == item.value.metadata!.exposureBias! }) {
                run.append(item)
            } else {
                flush()
                run = [item]
            }
        }
        flush()
        return sets
    }

    /// Panorama sequences: at least three frames, each overlapping the one
    /// before but shifted 12–90% of the frame, all in the same direction.
    static func panoramas(_ analyses: [String: PhotoAnalysis]) -> [[String]] {
        func isPan(_ l: PanLink) -> Bool {
            let m = max(abs(l.dx), abs(l.dy))
            return m >= 0.12 && m <= 0.9 && m >= 3 * min(abs(l.dx), abs(l.dy))
        }
        func direction(_ l: PanLink) -> Int {
            abs(l.dx) > abs(l.dy) ? (l.dx > 0 ? 1 : 2) : (l.dy > 0 ? 3 : 4)
        }
        // Follow links backward from each frame to build chains.
        var next: [String: String] = [:]
        for (name, a) in analyses {
            if let link = a.panLink, isPan(link), analyses[link.previous] != nil { next[link.previous] = name }
        }
        let starts = next.keys.filter { start in !next.values.contains(start) }
        var sets: [[String]] = []
        for start in starts.sorted() {
            var chain = [start]
            var current = start
            var dir: Int?
            while let n = next[current], let link = analyses[n]?.panLink {
                let d = direction(link)
                if let dir, dir != d { break }
                dir = d
                chain.append(n)
                current = n
            }
            if chain.count >= 3 { sets.append(chain) }
        }
        return sets
    }

    /// The main subject smiles (measured from the mouth, or Core Image's
    /// smile flag when landmarks are missing), eyes open, decent face quality.
    static func isMoment(_ a: PhotoAnalysis) -> Bool {
        guard let primary = a.primaryFace, primary.eyesClosed != true else { return false }
        let smiling = primary.mouth.map { Scorer.smile($0) >= Scorer.smiling } ?? (primary.smiling == true)
        return smiling && (primary.quality ?? 0) >= 0.45
    }
}
