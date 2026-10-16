import XCTest
@testable import KeepersCore

final class InteropTests: XCTestCase {
    func testWritesNewSidecar() throws {
        let dir = try Fixtures.tempDirectory()
        try Fixtures.touch(dir.appendingPathComponent("IMG_1.ORF"))
        let photo = try PhotoLibrary.scan(dir)[0]
        try XMPSidecar.write(XMPSidecar.mark(for: .picks), for: photo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("IMG_1.xmp").path))
        XCTAssertEqual(XMPSidecar.read(for: photo), XMPSidecar.Mark(rating: 5, label: "Green"))
        // Review clears the label and the stars.
        try XMPSidecar.write(XMPSidecar.mark(for: .review), for: photo)
        XCTAssertEqual(XMPSidecar.read(for: photo), XMPSidecar.Mark(rating: 0, label: nil))
    }

    func testUpdatesExistingSidecarKeepingEverythingElse() throws {
        let dir = try Fixtures.tempDirectory()
        try Fixtures.touch(dir.appendingPathComponent("DSC_1.NEF"))
        // A Lightroom-style sidecar with develop settings and the element form of Rating.
        let lightroom = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xap="http://ns.adobe.com/xap/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            crs:Exposure2012="+0.35" crs:WhiteBalance="As Shot">
           <xap:Rating>2</xap:Rating>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        try lightroom.write(to: dir.appendingPathComponent("DSC_1.xmp"), atomically: true, encoding: .utf8)
        let photo = try PhotoLibrary.scan(dir)[0]
        try XMPSidecar.write(XMPSidecar.mark(for: .trash), for: photo)

        let text = try String(contentsOf: dir.appendingPathComponent("DSC_1.xmp"))
        XCTAssertTrue(text.contains("crs:Exposure2012=\"+0.35\""))
        XCTAssertTrue(text.contains("<xap:Rating>-1</xap:Rating>"))
        XCTAssertFalse(text.contains("xmlns:xmp="), "reuses the file's existing prefix")
        XCTAssertEqual(XMPSidecar.read(for: photo), XMPSidecar.Mark(rating: -1, label: "Red"))
    }

    func testExportCopiesPairsAndSidecarsWithoutOverwriting() throws {
        let src = try Fixtures.tempDirectory(), dst = try Fixtures.tempDirectory()
        try Fixtures.touch(src.appendingPathComponent("A.ORF"), "raw")
        try Fixtures.touch(src.appendingPathComponent("A.JPG"), "jpg")
        try Fixtures.touch(src.appendingPathComponent("A.xmp"), "xmp")
        try Fixtures.touch(dst.appendingPathComponent("A.JPG"), "different")
        let photos = try PhotoLibrary.scan(src)
        let r = try Exporter.copy(photos, to: dst)
        XCTAssertEqual(r.copied, 3)
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("A.JPG")), "different")
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("A (2).JPG")), "jpg")
        // Running again copies nothing new.
        let again = try Exporter.copy(photos, to: dst)
        XCTAssertEqual(again.copied, 0)
        XCTAssertEqual(again.skipped, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent("A (3).JPG").path))
    }

    func testCardImportFindsPhotosUnderDCIM() throws {
        let volume = try Fixtures.tempDirectory()
        let sub = volume.appendingPathComponent("DCIM/100OLYMP", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for name in ["P1.ORF", "P1.JPG", "._P1.ORF", "notes.txt", "P2.MOV"] { try Fixtures.touch(sub.appendingPathComponent(name)) }
        let card = CardImport.Card(volume: volume)
        XCTAssertEqual(CardImport.photoFiles(on: card).map(\.lastPathComponent), ["P1.JPG", "P1.ORF"])
        let dst = try Fixtures.tempDirectory().appendingPathComponent("shoot")
        let r = try CardImport.importPhotos(from: card, to: dst)
        XCTAssertEqual(r.copied, 2)
        XCTAssertEqual(try PhotoLibrary.scan(dst).map(\.name), ["P1.ORF"])  // paired
        XCTAssertFalse(CardImport.isCard(volume), "a plain folder isn't a removable volume")
    }

    func testSuggestedImportFolderName() {
        let card = CardImport.Card(volume: URL(fileURLWithPath: "/Volumes/NIKON D750"))
        let date = ImageDecoder.parseExifDate("2026:10:16 09:00:00", subseconds: nil)!
        XCTAssertTrue(CardImport.suggestedFolder(for: card, date: date).lastPathComponent.hasSuffix("NIKON D750"))
    }
}
