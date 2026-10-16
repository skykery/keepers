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

    func testSubfoldersAreScannedWithPrefixedLinks() throws {
        let dir = try Fixtures.tempDirectory()
        let fm = FileManager.default
        for sub in ["Card A", "Card B", "Top Picks", ".hidden"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Fixtures.touch(dir.appendingPathComponent("root.jpg"))
        try Fixtures.touch(dir.appendingPathComponent("Card A/IMG_1.ORF"))
        try Fixtures.touch(dir.appendingPathComponent("Card A/IMG_1.JPG"))
        try Fixtures.touch(dir.appendingPathComponent("Card B/IMG_1.ORF"))
        try Fixtures.touch(dir.appendingPathComponent("Top Picks/old.jpg"))   // our output folder
        try Fixtures.touch(dir.appendingPathComponent(".hidden/x.jpg"))

        XCTAssertEqual(try PhotoLibrary.scan(dir).map(\.name), ["root.jpg"])
        let all = try PhotoLibrary.scan(dir, includeSubfolders: true)
        XCTAssertEqual(all.map(\.name), ["Card A/IMG_1.ORF", "Card B/IMG_1.ORF", "root.jpg"])
        XCTAssertEqual(all[0].companions.map(\.lastPathComponent), ["IMG_1.JPG"])

        try FolderOrganizer(outputDirectory: dir).apply([all[0]: .picks, all[1]: .picks])
        let links = try fm.contentsOfDirectory(atPath: dir.appendingPathComponent("Top Picks").path).sorted()
        XCTAssertEqual(links, ["Card A - IMG_1.JPG", "Card A - IMG_1.ORF", "Card B - IMG_1.ORF", "old.jpg"])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Top Picks/Card B - IMG_1.ORF")), "x")
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
        XCTAssertEqual(FolderOrganizer.destination(of: picks.appendingPathComponent("a.jpg"))?.hasPrefix("../"), true)
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

    func testRelativeLinksSurviveMovingTheFolder() throws {
        let parent = try Fixtures.tempDirectory()
        let shoot = parent.appendingPathComponent("shoot")
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        try Fixtures.touch(shoot.appendingPathComponent("a.jpg"), "original")
        let photo = try PhotoLibrary.scan(shoot)[0]
        try FolderOrganizer(outputDirectory: shoot).apply([photo: .picks])

        let moved = parent.appendingPathComponent("renamed")
        try FileManager.default.moveItem(at: shoot, to: moved)
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("Top Picks/a.jpg")), "original")
    }

    func testRelativePathAcrossDirectories() {
        let p = FolderOrganizer.relativePath(to: URL(fileURLWithPath: "/a/b/photo.jpg"),
                                             from: URL(fileURLWithPath: "/a/out/Top Picks"))
        XCTAssertEqual(p, "../../b/photo.jpg")
    }

    func testApplyReplacesAbsoluteLinksAndPlaceMovesOnePhoto() throws {
        let dir = try Fixtures.tempDirectory()
        try Fixtures.touch(dir.appendingPathComponent("a.orf"))
        try Fixtures.touch(dir.appendingPathComponent("a.jpg"))
        let photo = try PhotoLibrary.scan(dir)[0]
        let org = FolderOrganizer(outputDirectory: dir)
        // A 2.0-style absolute link.
        try FileManager.default.createDirectory(at: org.url(for: .review), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: org.url(for: .review).appendingPathComponent("a.orf"),
                                                   withDestinationURL: dir.appendingPathComponent("a.orf"))
        try org.apply([photo: .review])
        XCTAssertEqual(FolderOrganizer.destination(of: org.url(for: .review).appendingPathComponent("a.orf")), "../a.orf")

        try org.place(photo, in: .trash)
        for name in ["a.orf", "a.jpg"] {
            XCTAssertFalse(FolderOrganizer.isSymlink(org.url(for: .review).appendingPathComponent(name)))
            XCTAssertEqual(FolderOrganizer.destination(of: org.url(for: .trash).appendingPathComponent(name)), "../\(name)")
        }
    }

    func testLegacyPlacementsAreOfferedOnceAndImported() throws {
        let dir = try Fixtures.tempDirectory()
        try Fixtures.touch(dir.appendingPathComponent("a.jpg"))
        try Fixtures.touch(dir.appendingPathComponent("b.jpg"))
        try #"{"a.jpg": "Top Picks", "b.jpg": "Trash", "gone.jpg": "Review", "c.jpg": "Picks"}"#
            .write(to: dir.appendingPathComponent("organization.json"), atomically: true, encoding: .utf8)
        let photos = try PhotoLibrary.scan(dir)
        let store = SessionStore(outputDirectory: dir)
        let legacy = store.pendingLegacyPlacements(for: photos)
        XCTAssertEqual(legacy, ["a.jpg": .picks, "b.jpg": .trash])
        try store.resolveLegacyPlacements(legacy, importing: true)
        XCTAssertEqual(store.placements, ["a.jpg": .picks, "b.jpg": .trash])
        XCTAssertTrue(SessionStore(outputDirectory: dir).pendingLegacyPlacements(for: photos).isEmpty)
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
