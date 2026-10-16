import XCTest
@testable import KeepersCore

final class TasteTests: XCTestCase {
    func testLogRoundTrip() throws {
        let url = try Fixtures.tempDirectory().appendingPathComponent("taste.jsonl")
        Taste.record(Taste.Sample(sharpness: 0.9, exposure: 1, aesthetics: 0.7, folder: .picks), to: url)
        Taste.record(Taste.Sample(sharpness: 0.2, exposure: 1, aesthetics: nil, folder: .trash), to: url)
        let loaded = Taste.load(from: url)
        XCTAssertEqual(loaded.map(\.folder), [.picks, .trash])
        XCTAssertNil(loaded[1].aesthetics)
    }

    func testNeedsEnoughVariedChoices() {
        let few = (0..<10).map { _ in Taste.Sample(sharpness: 0.9, exposure: 1, aesthetics: 0.7, folder: .picks) }
        XCTAssertNil(Taste.fit(few))
        let oneFolder = (0..<40).map { i in Taste.Sample(sharpness: Double(i) / 40, exposure: 1, aesthetics: 0.7, folder: .review) }
        XCTAssertNil(Taste.fit(oneFolder))
    }

    func testLearnsThatSharpnessDecides() {
        // A photographer who keeps sharp photos regardless of aesthetics and
        // exposure (independent pseudo-random signals, fixed seed).
        var seed: UInt64 = 42
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        var samples: [Taste.Sample] = []
        for _ in 0..<80 {
            let sharp = next(), exposure = next(), aesthetics = next()
            samples.append(Taste.Sample(sharpness: sharp, exposure: exposure, aesthetics: aesthetics,
                                        folder: sharp >= 0.7 ? .picks : sharp >= 0.3 ? .review : .trash))
        }
        let fit = Taste.fit(samples)!
        XCTAssertGreaterThan(fit.weights.sharpness, 0.8)
        XCTAssertGreaterThan(fit.agreement, fit.defaultAgreement)
        XCTAssertGreaterThan(fit.agreement, 0.95)
    }

    func testGroupOverridesSplitAndJoin() {
        let items = [0.0, 0.5, 1.0, 100].enumerated().map { BurstGrouper.Item(id: "p\($0.offset)", date: Date(timeIntervalSince1970: $0.element), print: nil) }
        var g = BurstGrouper()
        XCTAssertEqual(g.group(items), [["p0", "p1", "p2"], ["p3"]])
        g.breaks = ["p1"]
        g.joins = ["p3"]
        XCTAssertEqual(g.group(items), [["p0"], ["p1", "p2", "p3"]])
        // Separating the middle frame keeps its neighbours together.
        var s = BurstGrouper()
        s.separated = ["p1"]
        XCTAssertEqual(s.group(items), [["p0", "p2"], ["p1"], ["p3"]])
    }

    func testCustomSettingsChangeDecisions() {
        var analyses: [String: PhotoAnalysis] = [:]
        for i in 0..<10 { analyses["p\(i)"] = Fixtures.analysis(date: Double(i) * 100, aesthetics: 0.5 + Double(i) * 0.02) }
        var settings = Preset.balanced.settings
        settings.pickFraction = 0.5
        let picks = Culler.cull(analyses, settings: settings).decisions.values.filter { $0.folder == .picks }.count
        XCTAssertEqual(picks, 5)
    }
}

final class UpdateTests: XCTestCase {
    func testParsesGitHubReleaseAndComparesVersions() {
        let json = #"{"tag_name": "v2.10.0", "html_url": "https://github.com/skykery/keepers/releases/tag/v2.10.0"}"#.data(using: .utf8)!
        let r = ReleaseInfo(json: json)!
        XCTAssertEqual(r.version, "2.10.0")
        XCTAssertTrue(r.isNewer(than: "2.9.1"))
        XCTAssertFalse(r.isNewer(than: "2.10.0"))
        XCTAssertFalse(r.isNewer(than: "3.0"))
        XCTAssertNil(ReleaseInfo(json: Data("{}".utf8)))
    }
}
