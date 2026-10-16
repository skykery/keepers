import XCTest
@testable import KeepersCore

final class MeasurementTests: XCTestCase {
    func testFocusEnergyDropsWithBlur() {
        let sharp = PixelBuffer(Fixtures.checkerboard())!
        let soft = PixelBuffer(Fixtures.checkerboard(blurRadius: 2))!
        let mush = PixelBuffer(Fixtures.checkerboard(blurRadius: 5))!
        let e = [sharp, soft, mush].map { PixelMetrics.focusEnergy($0) }
        XCTAssertGreaterThan(e[0], e[1])
        XCTAssertGreaterThan(e[1], e[2])
        XCTAssertGreaterThan(Scorer.sharpness(e[0]), 0.9)
    }

    func testFocusMapFindsTheSharpHalf() {
        let w = 512, h = 256
        let a = PixelBuffer(Fixtures.checkerboard(width: w, height: h))!
        let b = PixelBuffer(Fixtures.checkerboard(width: w, height: h, blurRadius: 6))!
        var mixed = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { mixed[y * w + x] = UInt8(x < w / 2 ? a.luma[y * w + x] : b.luma[y * w + x]) } }
        let map = PixelMetrics.focusMap(PixelBuffer(Fixtures.gray(mixed, w, h))!, tile: 64)
        XCTAssertEqual(map.columns, 8)
        XCTAssertEqual(map.rows, 4)
        XCTAssertGreaterThan(map.sharpness(column: 1, row: 1), 0.9)
        XCTAssertLessThan(map.sharpness(column: 6, row: 1), 0.5)
    }

    func testDecodeLargeReturnsFullResolutionForJPEG() throws {
        let dir = try Fixtures.tempDirectory()
        let url = try Fixtures.writeJPEG(Fixtures.checkerboard(width: 900, height: 600), to: dir.appendingPathComponent("a.jpg"))
        let large = try ImageDecoder.decodeLarge(url, full: false)
        XCTAssertEqual(large.image.width, 900)
        XCTAssertEqual(large.nativeSize, CGSize(width: 900, height: 600))
        XCTAssertTrue(large.isFullResolution)
    }

    func testFocusEnergyOfFlatImageIsZero() {
        XCTAssertEqual(PixelMetrics.focusEnergy(PixelBuffer(Fixtures.flat(value: 128))!), 0, accuracy: 1e-6)
    }

    func testMaxSideMakesFocusScaleIndependent() {
        // The same pattern at 2x size has fewer edges per tile; measured at a
        // capped size the two should read about the same.
        let small = PixelBuffer(Fixtures.checkerboard(width: 256, height: 256, cell: 8))!
        let large = PixelBuffer(Fixtures.checkerboard(width: 512, height: 512, cell: 16))!
        let a = PixelMetrics.focusEnergy(small, maxSide: 256)
        let b = PixelMetrics.focusEnergy(large, maxSide: 256)
        XCTAssertEqual(b / a, 1, accuracy: 0.35)
        XCTAssertLessThan(PixelMetrics.focusEnergy(large), b)
    }

    func testFocusEnergyUsesSharpestTiles() {
        // Left half sharp, right half blurred: a sharp subject on a soft
        // background must still read as sharp.
        let w = 512, h = 256
        let sharp = Fixtures.checkerboard(width: w, height: h)
        let soft = Fixtures.checkerboard(width: w, height: h, blurRadius: 6)
        let a = PixelBuffer(sharp)!, b = PixelBuffer(soft)!
        var mixed = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            mixed[y * w + x] = UInt8(x < w / 2 ? a.luma[y * w + x] : b.luma[y * w + x])
        } }
        let energy = PixelMetrics.focusEnergy(PixelBuffer(Fixtures.gray(mixed, w, h))!)
        XCTAssertGreaterThan(energy, PixelMetrics.focusEnergy(b) * 5)
    }

    func testExposureClipping() {
        let white = PixelMetrics.exposure(PixelBuffer(Fixtures.flat(value: 255))!, subject: .full)
        XCTAssertEqual(white.highlightClip, 1, accuracy: 1e-9)
        XCTAssertEqual(white.subjectLuminance, 1, accuracy: 0.01)
        let black = PixelMetrics.exposure(PixelBuffer(Fixtures.flat(value: 0))!, subject: .full)
        XCTAssertEqual(black.shadowClip, 1, accuracy: 1e-9)
        let mid = PixelMetrics.exposure(PixelBuffer(Fixtures.flat(value: 128))!, subject: .full)
        XCTAssertEqual(mid.highlightClip, 0)
        XCTAssertEqual(mid.shadowClip, 0)
        XCTAssertEqual(Scorer.exposureScore(mid), 1, accuracy: 1e-9)
        XCTAssertEqual(Scorer.exposureScore(white), 0, accuracy: 1e-9)
    }

    func testNormRectConversions() {
        let r = NormRect(bottomLeft: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        XCTAssertEqual(r.y, 0.4, accuracy: 1e-9)
        XCTAssertEqual(r.intersectionOverUnion(r), 1, accuracy: 1e-9)
        XCTAssertEqual(r.intersectionOverUnion(NormRect(x: 0.6, y: 0, width: 0.1, height: 0.1)), 0)
        XCTAssertEqual(NormRect(x: -0.5, y: 0.5, width: 1, height: 1).clamped(), NormRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
    }

    func testFeaturePrintDistance() {
        let a = FeaturePrint(revision: 2, vector: [1, 0, 0])
        XCTAssertEqual(a.distance(to: a)!, 0, accuracy: 1e-6)
        XCTAssertEqual(a.distance(to: FeaturePrint(revision: 2, vector: [0, 1, 0]))!, 1, accuracy: 1e-6)
        XCTAssertNil(a.distance(to: FeaturePrint(revision: 1, vector: [1, 0, 0])))
    }

    func testFeaturePrintCodableRoundTripAndLegacyFormat() throws {
        let fp = FeaturePrint(revision: 2, vector: [0.5, -1.25, 3])
        let data = try JSONEncoder().encode(fp)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("vector"))
        XCTAssertEqual(try JSONDecoder().decode(FeaturePrint.self, from: data), fp)
        let legacy = #"{"revision":2,"vector":[0.5,-1.25,3]}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(FeaturePrint.self, from: legacy), fp)
    }

    func testExifDateParsing() {
        let d = ImageDecoder.parseExifDate("2025:02:24 12:19:28", subseconds: "30")!
        let base = ImageDecoder.parseExifDate("2025:02:24 12:19:28", subseconds: nil)!
        XCTAssertEqual(d.timeIntervalSince(base), 0.30, accuracy: 1e-6)
        XCTAssertNil(ImageDecoder.parseExifDate("garbage", subseconds: nil))
    }

    func testAnalyzerOnSyntheticImage() throws {
        let analysis = try Analyzer(aestheticsModel: nil)
            .analyze(Fixtures.checkerboard(width: 640, height: 480), captureDate: Date())
        XCTAssertEqual(analysis.pixelWidth, 640)
        XCTAssertTrue(analysis.faces.isEmpty)
        XCTAssertGreaterThan(Scorer.sharpness(analysis.globalFocus), 0.9)
        XCTAssertNotNil(analysis.featurePrint)
    }

    func testDecodeReadsJPEGAndExifDate() throws {
        let dir = try Fixtures.tempDirectory()
        let url = try Fixtures.writeJPEG(Fixtures.checkerboard(width: 800, height: 600),
                                         to: dir.appendingPathComponent("a.jpg"), exifDate: "2024:06:01 10:00:00")
        let decoded = try ImageDecoder.decode(url, maxPixelSize: 400)
        XCTAssertEqual(max(decoded.image.width, decoded.image.height), 400)
        XCTAssertEqual(decoded.captureDate, ImageDecoder.parseExifDate("2024:06:01 10:00:00", subseconds: nil))
        XCTAssertThrowsError(try ImageDecoder.decode(dir.appendingPathComponent("missing.jpg"), maxPixelSize: 400))
    }
}
