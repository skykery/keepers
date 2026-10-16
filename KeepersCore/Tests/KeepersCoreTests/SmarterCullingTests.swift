import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import KeepersCore

final class SmarterCullingTests: XCTestCase {
    func testBracketIsKeptTogetherAndNeverFailsOnExposure() {
        let analyses = [
            "under": Fixtures.analysis(date: 0, shadowClip: 0.8, luminance: 0.05, bias: -2),
            "base": Fixtures.analysis(date: 0.4, aesthetics: 0.9, bias: 0),
            "over": Fixtures.analysis(date: 0.8, highlightClip: 0.5, luminance: 0.95, bias: 2),
            "other": Fixtures.analysis(date: 100, aesthetics: 0.5),
        ]
        let r = Culler.cull(analyses, preset: .balanced)
        XCTAssertEqual(r.decisions["base"]?.folder, .picks)
        XCTAssertEqual(r.decisions["under"]?.folder, .picks)
        XCTAssertEqual(r.decisions["over"]?.folder, .picks)
        XCTAssertEqual(r.decisions["under"]?.reasons.first, "Exposure bracket: −2, 0, +2 EV")
        XCTAssertTrue(r.decisions["base"]!.reasons.contains("Exposure bracket: −2, 0, +2 EV"))
    }

    func testSameExposureBurstIsNotABracket() {
        let analyses = [
            "a": Fixtures.analysis(date: 0, bias: 0),
            "b": Fixtures.analysis(date: 0.3, bias: 0),
            "dark": Fixtures.analysis(date: 0.6, aesthetics: 0.3, shadowClip: 0.9, bias: 0),
        ]
        XCTAssertTrue(Culler.brackets(analyses).isEmpty)
        XCTAssertEqual(Culler.cull(analyses, preset: .balanced).decisions["dark"]?.folder, .trash)
    }

    func testIntentionalLowKeyIsNotTrashed() {
        let lowKey = Fixtures.analysis(aesthetics: 0.8, shadowClip: 0.8, luminance: 0.1)
        let mistake = Fixtures.analysis(date: 100, aesthetics: 0.4, shadowClip: 0.8, luminance: 0.1)
        let r = Culler.cull(["lowKey": lowKey, "mistake": mistake], preset: .balanced)
        XCTAssertNotEqual(r.decisions["lowKey"]?.folder, .trash)
        XCTAssertTrue(r.decisions["lowKey"]!.reasons.contains("Very dark, but looks intentional"))
        XCTAssertEqual(r.decisions["mistake"]?.reasons, ["Severely underexposed"])
    }

    func testPanningShotWithSharpSubjectPasses() {
        // Sharp subject, streaked (soft) background.
        var pan = Fixtures.analysis(focus: 60)
        pan.globalFocus = 2
        XCTAssertNil(Scorer.score(pan, gate: Preset.strict.gate).rejection)
    }

    func testPanoramaSequenceGoesToReviewTogether() {
        var analyses: [String: PhotoAnalysis] = [:]
        analyses["p1"] = Fixtures.analysis(date: 0, aesthetics: 0.3)
        for i in 2...4 {
            analyses["p\(i)"] = Fixtures.analysis(date: Double(i), aesthetics: 0.3,
                                                  panLink: PanLink(previous: "p\(i - 1)", dx: 0.4, dy: 0.02))
        }
        let r = Culler.cull(analyses, preset: .balanced)
        for i in 1...4 { XCTAssertEqual(r.decisions["p\(i)"]?.folder, .review, "p\(i)") }
        XCTAssertEqual(r.decisions["p3"]?.reasons, ["Panorama sequence: frame 3 of 4"])
        XCTAssertTrue(r.groups.contains(["p1", "p2", "p3", "p4"]))
    }

    func testPanoramaNeedsOneDirectionAndRealShifts() {
        func chain(_ links: [(Double, Double)]) -> [String: PhotoAnalysis] {
            var a = ["p0": Fixtures.analysis(date: 0)]
            for (i, l) in links.enumerated() {
                a["p\(i + 1)"] = Fixtures.analysis(date: Double(i + 1), panLink: PanLink(previous: "p\(i)", dx: l.0, dy: l.1))
            }
            return a
        }
        XCTAssertTrue(Culler.panoramas(chain([(0.4, 0), (-0.4, 0)])).isEmpty)   // back and forth
        XCTAssertTrue(Culler.panoramas(chain([(0.03, 0), (0.02, 0)])).isEmpty)   // a burst's jitter
        XCTAssertEqual(Culler.panoramas(chain([(0, 0.3), (0, 0.35)])).count, 1) // vertical pano
    }

    func testFewerBlinksRankHigherAndEveryoneOpenIsNoted() {
        let open = [Fixtures.face(quality: 0.5), Fixtures.face(quality: 0.5, rect: NormRect(x: 0.1, y: 0.3, width: 0.2, height: 0.25))]
        let oneBlink = [Fixtures.face(quality: 0.9), Fixtures.face(quality: 0.9, eyesClosed: true, rect: NormRect(x: 0.1, y: 0.3, width: 0.2, height: 0.25))]
        let r = Culler.cull([
            "blink": Fixtures.analysis(date: 0, aesthetics: 0.95, faces: oneBlink),
            "open": Fixtures.analysis(date: 0.3, aesthetics: 0.7, faces: open),
        ], preset: .balanced)
        XCTAssertEqual(r.groups.first, ["open", "blink"])
        XCTAssertTrue(r.decisions["open"]!.reasons.contains("Everyone's eyes open"))
    }

    func testNikonFocusPointParsing() {
        // Two unused points and the used center point (x, y = corner).
        let af: [Any] = ["0.1", "0.1", "0.04", "0.05", "n", "0.48", "0.475", "0.04", "0.05", "F", "0.8", "0.8", "0.04", "0.05", "n"]
        let p = ImageDecoder.focusPoint(afInfo: af, orientation: 1)!
        XCTAssertEqual(p.midX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.midY, 0.5, accuracy: 1e-9)
        let left = ImageDecoder.focusPoint(afInfo: ["0.1", "0.45", "0.04", "0.1", "F"], orientation: 1)!
        let rotated = ImageDecoder.focusPoint(afInfo: ["0.1", "0.45", "0.04", "0.1", "F"], orientation: 6)!
        XCTAssertEqual(left.midX, 0.12, accuracy: 1e-9)
        // Rotated 90° clockwise, the left edge becomes the top.
        XCTAssertEqual(rotated.midY, 0.12, accuracy: 1e-9)
        XCTAssertNil(ImageDecoder.focusPoint(afInfo: ["0.1", "0.1", "0.04", "0.05", "n"], orientation: 1))
    }

    func testTranslationBetweenOverlappingFrames() throws {
        // Two crops of one textured image, the second 30% further right.
        var rng = SystemRandomNumberGenerator()
        let w = 1000, h = 400
        var pixels = [UInt8](repeating: 0, count: w * h)
        for i in pixels.indices { pixels[i] = UInt8.random(in: 0...255, using: &rng) }
        let big = Fixtures.gray(Fixtures.boxBlur(pixels, w, h, 3), w, h)
        let dir = try Fixtures.tempDirectory()
        let a = try Fixtures.writeJPEG(big.cropping(to: CGRect(x: 0, y: 0, width: 500, height: 400))!, to: dir.appendingPathComponent("a.jpg"))
        let b = try Fixtures.writeJPEG(big.cropping(to: CGRect(x: 150, y: 0, width: 500, height: 400))!, to: dir.appendingPathComponent("b.jpg"))
        let shift = try Analyzer.translation(from: Photo(primary: a), to: Photo(primary: b))
        XCTAssertEqual(shift.dx, 0.3, accuracy: 0.05)
        XCTAssertEqual(shift.dy, 0, accuracy: 0.05)

        // Vertical: the second crop 25% lower in the image (rows count down).
        let tall = Fixtures.gray(Fixtures.boxBlur(pixels, h, w, 3), h, w)  // 400 × 1000
        let c = try Fixtures.writeJPEG(tall.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 500))!, to: dir.appendingPathComponent("c.jpg"))
        let d = try Fixtures.writeJPEG(tall.cropping(to: CGRect(x: 0, y: 125, width: 400, height: 500))!, to: dir.appendingPathComponent("d.jpg"))
        let down = try Analyzer.translation(from: Photo(primary: c), to: Photo(primary: d))
        XCTAssertEqual(down.dy, 0.25, accuracy: 0.05)
        XCTAssertEqual(down.dx, 0, accuracy: 0.05)
    }
}
