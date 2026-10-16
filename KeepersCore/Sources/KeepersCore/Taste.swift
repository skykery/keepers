import Foundation

/// Learning scoring weights from the folders a photographer picks by hand.
///
/// Every manual move is logged with the photo's signals, across shoots.
/// `fit` then searches the weights that best order those choices (Top Picks
/// and Moments above Review above Trash). Nothing leaves the Mac.
public enum Taste {
    public struct Sample: Codable, Hashable, Sendable {
        public var sharpness: Double
        public var exposure: Double
        public var aesthetics: Double?
        public var folder: Folder
        public var date: Date

        public init(sharpness: Double, exposure: Double, aesthetics: Double?, folder: Folder, date: Date = Date()) {
            self.sharpness = sharpness; self.exposure = exposure; self.aesthetics = aesthetics
            self.folder = folder; self.date = date
        }

        public init(_ score: PhotoScore, folder: Folder) {
            self.init(sharpness: score.sharpness, exposure: score.exposure, aesthetics: score.aesthetics, folder: folder)
        }

        /// How much the photographer wanted it: picks and moments 2, review 1, trash 0.
        var level: Int {
            switch folder {
            case .picks, .moments: return 2
            case .review: return 1
            case .trash: return 0
            }
        }
    }

    public static var logURL: URL { AppPaths.supportDirectory.appendingPathComponent("taste.jsonl") }

    /// Appends one manual choice to the log.
    public static func record(_ sample: Sample, to url: URL = logURL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard var line = try? encoder.encode(sample) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    public static func load(from url: URL = logURL) -> [Sample] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let text = try? String(contentsOf: url) else { return [] }
        return text.split(separator: "\n").compactMap { try? decoder.decode(Sample.self, from: Data($0.utf8)) }
    }

    public static func reset(at url: URL = logURL) { try? FileManager.default.removeItem(at: url) }

    public struct Fit: Sendable {
        public var weights: ScoringWeights
        /// Share of differently-placed photo pairs the weights order like you did.
        public var agreement: Double
        public var defaultAgreement: Double
        public var samples: Int
    }

    /// Needs choices in at least two different levels and `minimumSamples`.
    public static let minimumSamples = 30

    /// Grid search over the sharpness / exposure / aesthetics weights (steps
    /// of 0.05, summing to 1), using the most recent 400 choices.
    public static func fit(_ all: [Sample]) -> Fit? {
        let samples = Array(all.sorted { $0.date > $1.date }.prefix(400))
        guard samples.count >= minimumSamples, Set(samples.map(\.level)).count >= 2 else { return nil }
        var pairs: [(Int, Int)] = []  // (preferred, other)
        for i in samples.indices {
            for j in samples.indices where samples[i].level > samples[j].level { pairs.append((i, j)) }
        }
        func agreement(_ w: ScoringWeights) -> Double {
            let q = samples.map { Scorer.combine(sharpness: $0.sharpness, exposure: $0.exposure, aesthetics: $0.aesthetics, weights: w) }
            var concordant = 0.0
            for (a, b) in pairs { concordant += q[a] > q[b] ? 1 : q[a] == q[b] ? 0.5 : 0 }
            return concordant / Double(pairs.count)
        }
        let defaults = ScoringWeights()
        let defaultScore = agreement(defaults)
        func distance(_ w: ScoringWeights) -> Double {
            abs(w.sharpness - defaults.sharpness) + abs(w.exposure - defaults.exposure) + abs(w.aesthetics - defaults.aesthetics)
        }
        var candidates: [(weights: ScoringWeights, score: Double)] = []
        for s in 0...20 {
            for e in 0...(20 - s) {
                var w = ScoringWeights()
                w.sharpness = Double(s) / 20
                w.exposure = Double(e) / 20
                w.aesthetics = Double(20 - s - e) / 20
                candidates.append((w, agreement(w)))
            }
        }
        let top = candidates.map(\.score).max() ?? defaultScore
        // Stay with the defaults unless clearly better (avoids fitting noise);
        // among equally good weights, take the ones closest to the defaults.
        guard top > defaultScore + 0.01 else {
            return Fit(weights: defaults, agreement: defaultScore, defaultAgreement: defaultScore, samples: samples.count)
        }
        let best = candidates.filter { $0.score >= top - 0.001 }.min { distance($0.weights) < distance($1.weights) }!
        return Fit(weights: best.weights, agreement: best.score, defaultAgreement: defaultScore, samples: samples.count)
    }
}
