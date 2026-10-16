import XCTest
@testable import KeepersCore

final class SessionTests: XCTestCase {
    func testScanPairsRawWithJpegAndSkipsJunk() throws {
        let dir = try Fixtures.tempDirectory()
        for name in ["IMG_1.ORF", "IMG_1.JPG", "IMG_2.nef", "IMG_3.jpeg", "._IMG_3.jpeg", "notes.txt", ".hidden.jpg"] {
            try Fixtures.touch(dir.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub.jpg"), withIntermediateDirectories: true)

        let photos = try PhotoLibrary.scan(dir)
        XCTAssertEqual(photos.map(\.name), ["IMG_1.ORF", "IMG_2.nef", "IMG_3.jpeg"])
        XCTAssertEqual(photos[0].companions.map(\.lastPathComponent), ["IMG_1.JPG"])
        XCTAssertEqual(photos[0].decodeURL.lastPathComponent, "IMG_1.JPG")
        XCTAssertEqual(photos[1].decodeURL.lastPathComponent, "IMG_2.nef")
    }

    func testOrganizerLinksAllFilesAndCleansUp() throws {
        let src = try Fixtures.tempDirectory(), out = try Fixtures.tempDirectory()
        try Fixtures.touch(src.appendingPathComponent("a.orf"))
        try Fixtures.touch(src.appendingPathComponent("a.jpg"))
        try Fixtures.touch(src.appendingPathComponent("b.jpg"))
        let photos = try PhotoLibrary.scan(src)
        let a = photos.first { $0.name == "a.orf" }!, b = photos.first { $0.name == "b.jpg" }!
        let org = FolderOrganizer(outputDirectory: out)

        try org.apply([a: .picks, b: .trash])
        let picks = org.url(for: .picks)
        let linked = picks.appendingPathComponent("a.jpg").resolvingSymlinksInPath()
        XCTAssertEqual(linked.path, src.appendingPathComponent("a.jpg").resolvingSymlinksInPath().path)
        XCTAssertTrue(FolderOrganizer.isSymlink(picks.appendingPathComponent("a.orf")))

        // A file the user put in our folder is left alone.
        try Fixtures.touch(org.url(for: .review).appendingPathComponent("b.jpg"))
        try org.apply([a: .review, b: .review])
        XCTAssertFalse(FileManager.default.fileExists(atPath: picks.appendingPathComponent("a.orf").path))
        XCTAssertFalse(FolderOrganizer.isSymlink(org.url(for: .trash).appendingPathComponent("b.jpg")))
        XCTAssertFalse(FolderOrganizer.isSymlink(org.url(for: .review).appendingPathComponent("b.jpg")))
        XCTAssertTrue(FolderOrganizer.isSymlink(org.url(for: .review).appendingPathComponent("a.orf")))
        // Originals untouched.
        XCTAssertEqual(try String(contentsOf: src.appendingPathComponent("a.orf")), "x")
    }

    func testStoreInvalidatesChangedFiles() throws {
        let dir = try Fixtures.tempDirectory()
        let url = dir.appendingPathComponent("a.jpg")
        try Fixtures.touch(url)
        let photo = Photo(primary: url)
        let store = SessionStore(outputDirectory: dir)
        store.setAnalysis(Fixtures.analysis(), for: photo)
        try store.saveAnalyses()

        XCTAssertNotNil(SessionStore(outputDirectory: dir).analysis(for: photo))
        try Fixtures.touch(url, "changed contents")
        XCTAssertNil(SessionStore(outputDirectory: dir).analysis(for: photo))
    }

    func testEndToEndSessionWithManualOverride() async throws {
        let dir = try Fixtures.tempDirectory()
        try Fixtures.writeJPEG(Fixtures.checkerboard(), to: dir.appendingPathComponent("sharp.jpg"), exifDate: "2024:01:01 10:00:00")
        try Fixtures.writeJPEG(Fixtures.checkerboard(blurRadius: 12), to: dir.appendingPathComponent("blurry.jpg"), exifDate: "2024:01:01 11:00:00")

        let session = try CullSession(inputDirectory: dir)
        XCTAssertEqual(session.pendingCount, 2)
        var reports = 0
        try await session.analyze(analyzer: Analyzer(aestheticsModel: nil), concurrency: 2) { _ in reports += 1 }
        XCTAssertEqual(reports, 3)
        try session.decide(preset: .balanced)
        XCTAssertEqual(session.folder(of: "blurry.jpg"), .trash)
        XCTAssertTrue(FolderOrganizer.isSymlink(dir.appendingPathComponent("Trash/blurry.jpg")))

        try session.move("blurry.jpg", to: .picks)
        XCTAssertTrue(session.isManual("blurry.jpg"))
        XCTAssertTrue(FolderOrganizer.isSymlink(dir.appendingPathComponent("Top Picks/blurry.jpg")))
        XCTAssertFalse(FolderOrganizer.isSymlink(dir.appendingPathComponent("Trash/blurry.jpg")))

        // A new session on the same folder reuses the analysis and the manual move.
        let again = try CullSession(inputDirectory: dir)
        XCTAssertEqual(again.pendingCount, 0)
        try await again.analyze()
        try again.decide(preset: .strict)
        XCTAssertEqual(again.folder(of: "blurry.jpg"), .picks)

        try again.move("blurry.jpg", to: nil)
        XCTAssertEqual(again.folder(of: "blurry.jpg"), .trash)
    }
}
