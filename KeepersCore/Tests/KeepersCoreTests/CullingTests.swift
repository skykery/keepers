import XCTest
@testable import KeepersCore

final class CullingTests: XCTestCase {
    func testGateTrashesOnlyClearFailures() {
        let gate = Preset.balanced.gate
        XCTAssertNil(Scorer.score(Fixtures.analysis(), gate: gate).rejection)
        XCTAssertEqual(Scorer.score(Fixtures.analysis(focus: 1), gate: gate).rejection, "Out of focus")
        XCTAssertEqual(Scorer.score(Fixtures.analysis(highlightClip: 0.5), gate: gate).rejection, "Blown highlights")
        XCTAssertEqual(Scorer.score(Fixtures.analysis(shadowClip: 0.8), gate: gate).rejection, "Severely underexposed")
        // Soft subject, but something in the frame is sharp: not a miss.
        var bokeh = Fixtures.analysis(focus: 1)
        bokeh.globalFocus = 60
        XCTAssertNil(Scorer.score(bokeh, gate: gate).rejection)
    }

    func testMissingAestheticsReweightsInsteadOfPenalizing() {
        let gate = Preset.balanced.gate
        let without = Scorer.score(Fixtures.analysis(aesthetics: nil), gate: gate)
        let perfect = Scorer.score(Fixtures.analysis(focus: 1000, aesthetics: 1), gate: gate)
        XCTAssertGreaterThan(without.quality, 0.9)
        XCTAssertEqual(perfect.quality, 1, accuracy: 0.01)
    }

    func testClosedEyesIsAFlawNotARejection() {
        let s = Scorer.score(Fixtures.analysis(faces: [Fixtures.face(eyesClosed: true)]), gate: Preset.balanced.gate)
        XCTAssertNil(s.rejection)
        XCTAssertEqual(s.flaws, ["Eyes closed"])
    }

    func testBurstGrouping() {
        let near = FeaturePrint(revision: 2, vector: [1, 0.05, 0])
        let same = FeaturePrint(revision: 2, vector: [1, 0, 0])
        let other = FeaturePrint(revision: 2, vector: [0, 1, 0])
        let items = [
            BurstGrouper.Item(id: "a", date: Date(timeIntervalSince1970: 0), print: other),
            BurstGrouper.Item(id: "b", date: Date(timeIntervalSince1970: 0.5), print: same),   // burst: time alone
            BurstGrouper.Item(id: "c", date: Date(timeIntervalSince1970: 10), print: near),    // re-take: looks alike
            BurstGrouper.Item(id: "d", date: Date(timeIntervalSince1970: 20), print: other),   // different scene
            BurstGrouper.Item(id: "e", date: Date(timeIntervalSince1970: 500), print: other),  // much later
        ]
        XCTAssertEqual(BurstGrouper().group(items.shuffled()), [["a", "b", "c"], ["d"], ["e"]])
    }

    func testOnePickPerBurstAndBudget() {
        var analyses: [String: PhotoAnalysis] = [:]
        // 10 frames of one burst, all great.
        for i in 0..<10 { analyses["burst\(i)"] = Fixtures.analysis(date: Double(i) * 0.2, aesthetics: 0.9 - Double(i) * 0.01) }
        // 10 distinct, decent shots far apart.
        for i in 0..<10 { analyses["solo\(i)"] = Fixtures.analysis(date: 1000 + Double(i) * 100, aesthetics: 0.6 + Double(i) * 0.01) }
        let r = Culler.cull(analyses, preset: .balanced)
        let picks = r.decisions.filter { $0.value.folder == .picks }.keys.sorted()
        XCTAssertEqual(picks, ["burst0", "solo8", "solo9"])  // 15% of 20
        XCTAssertEqual(r.decisions["burst1"]?.folder, .review)
        XCTAssertEqual(r.decisions["burst1"]?.rankInGroup, 2)
        XCTAssertTrue(r.decisions["burst1"]!.reasons.contains("#2 of 10 similar shots"))
        // Balanced keeps the best 3 frames of a group; the rest are duplicates.
        XCTAssertEqual(r.decisions["burst2"]?.folder, .review)
        XCTAssertEqual(r.decisions["burst3"]?.folder, .trash)
        XCTAssertEqual(r.decisions["burst3"]?.reasons.first, "Weaker duplicate: #4 of 10 similar shots")
    }

    func testPresetsChangePickCount() {
        var analyses: [String: PhotoAnalysis] = [:]
        for i in 0..<40 { analyses["p\(i)"] = Fixtures.analysis(date: Double(i) * 100, aesthetics: 0.5 + Double(i) * 0.01) }
        func picks(_ p: Preset) -> Int { Culler.cull(analyses, preset: p).decisions.values.filter { $0.folder == .picks }.count }
        XCTAssertEqual(picks(.strict), 2)
        XCTAssertEqual(picks(.balanced), 6)
        XCTAssertEqual(picks(.lenient), 10)
    }

    func testClearlyWorseDuplicateGoesToTrash() {
        let analyses = [
            "good": Fixtures.analysis(date: 0, aesthetics: 0.9),
            "worse": Fixtures.analysis(date: 0.5, aesthetics: 0.75),  // 0.0675 lower: past balanced, within lenient
            "close": Fixtures.analysis(date: 1.0, aesthetics: 0.88),  // within the gap
        ]
        let r = Culler.cull(analyses, preset: .balanced)
        XCTAssertEqual(r.decisions["good"]?.folder, .picks)
        XCTAssertEqual(r.decisions["close"]?.folder, .review)
        XCTAssertEqual(r.decisions["worse"]?.folder, .trash)
        XCTAssertEqual(Culler.cull(analyses, preset: .lenient).decisions["worse"]?.folder, .review)
    }

    func testDuplicateRankedLowerOnlyByFaceIsNotTrashed() {
        // "c" scores highest but ranks last because of face quality.
        var analyses: [String: PhotoAnalysis] = [:]
        analyses["a"] = Fixtures.analysis(date: 0, aesthetics: 0.80, faces: [Fixtures.face(quality: 0.9)])
        analyses["b"] = Fixtures.analysis(date: 0.3, aesthetics: 0.80, faces: [Fixtures.face(quality: 0.8)])
        analyses["c"] = Fixtures.analysis(date: 0.6, aesthetics: 0.82, faces: [Fixtures.face(quality: 0.2)])
        let r = Culler.cull(analyses, preset: .strict)
        XCTAssertEqual(r.groups, [["a", "b", "c"]])
        XCTAssertEqual(r.decisions["c"]?.rankInGroup, 3)
        XCTAssertEqual(r.decisions["c"]?.folder, .review)
    }

    func testDetailFocusPicksTheSharpestFrameOfABurst() {
        var a = Fixtures.analysis(date: 0, aesthetics: 0.80); a.detailFocus = 10
        var b = Fixtures.analysis(date: 0.3, aesthetics: 0.81); b.detailFocus = 40
        let r = Culler.cull(["a": a, "b": b], preset: .balanced)
        XCTAssertEqual(r.groups, [["b", "a"]])
        XCTAssertEqual(r.decisions["b"]?.folder, .picks)
        XCTAssertTrue(r.decisions["b"]!.reasons.contains("Sharpest of its group at full resolution"))
        // Without the measurement, the higher aesthetics alone decide.
        a.detailFocus = nil; b.detailFocus = nil; a.aesthetics = 0.82
        XCTAssertEqual(Culler.cull(["a": a, "b": b], preset: .balanced).groups, [["a", "b"]])
    }

    func testFlawedFrameRanksBelowFlawlessOnes() {
        var blink = Fixtures.analysis(date: 0, aesthetics: 0.95, faces: [Fixtures.face(quality: 0.9, eyesClosed: true)])
        blink.detailFocus = 100
        var open = Fixtures.analysis(date: 0.3, aesthetics: 0.6, faces: [Fixtures.face(quality: 0.3)])
        open.detailFocus = 5
        XCTAssertEqual(Culler.cull(["blink": blink, "open": open], preset: .balanced).groups, [["open", "blink"]])
    }

    func testBlinkingFrameIsNeverAPick() {
        let analyses = [
            "blink": Fixtures.analysis(date: 0, aesthetics: 0.95, faces: [Fixtures.face(eyesClosed: true)]),
            "open": Fixtures.analysis(date: 100, aesthetics: 0.6, faces: [Fixtures.face()]),
        ]
        let r = Culler.cull(analyses, preset: .balanced)
        XCTAssertEqual(r.decisions["open"]?.folder, .picks)
        XCTAssertEqual(r.decisions["blink"]?.folder, .review)
    }

    func testFaceQualityRanksWithinBurst() {
        let analyses = [
            "a": Fixtures.analysis(date: 0, faces: [Fixtures.face(quality: 0.3)]),
            "b": Fixtures.analysis(date: 0.3, faces: [Fixtures.face(quality: 0.8)]),
        ]
        XCTAssertEqual(Culler.cull(analyses, preset: .balanced).groups, [["b", "a"]])
    }

    func testMomentsTakeSmilesFromGroupsWithoutAPick() {
        var analyses: [String: PhotoAnalysis] = [:]
        for i in 0..<9 { analyses["s\(i)"] = Fixtures.analysis(date: Double(i) * 100, aesthetics: 0.9) }
        analyses["smile"] = Fixtures.analysis(date: 5000, aesthetics: 0.85, faces: [Fixtures.face(smiling: true)])
        analyses["frown"] = Fixtures.analysis(date: 6000, aesthetics: 0.85, faces: [Fixtures.face()])
        let r = Culler.cull(analyses, preset: .strict)
        XCTAssertEqual(r.decisions["smile"]?.folder, .moments)
        XCTAssertEqual(r.decisions["frown"]?.folder, .review)
    }

    func testRejectedPhotosGoToTrash() {
        let r = Culler.cull(["blurry": Fixtures.analysis(focus: 0.5), "ok": Fixtures.analysis()], preset: .balanced)
        XCTAssertEqual(r.decisions["blurry"]?.folder, .trash)
        XCTAssertEqual(r.decisions["blurry"]?.reasons, ["Out of focus"])
        XCTAssertEqual(r.decisions["ok"]?.folder, .picks)
    }

    func testQualityFloorBlocksWeakPicks() {
        let r = Culler.cull(["meh": Fixtures.analysis(focus: 8, aesthetics: 0.1, luminance: 0.1)], preset: .strict)
        XCTAssertEqual(r.decisions["meh"]?.folder, .review)
        XCTAssertTrue(r.decisions["meh"]!.reasons.contains("Below the quality bar for a pick"))
    }
}
