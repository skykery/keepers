import Foundation

// MARK: - XMP ratings

/// Star ratings and color labels in XMP sidecars (`IMG_001.xmp` next to
/// `IMG_001.ORF`), the convention Lightroom Classic, Capture One, and Bridge
/// read on import. Originals are never written; an existing sidecar is
/// updated in place, keeping everything else in it.
public enum XMPSidecar {
    public struct Mark: Equatable {
        /// -1 (rejected) or 0–5.
        public var rating: Int
        /// Lightroom's default label names: Red, Yellow, Green, Blue, Purple. Nil removes the label.
        public var label: String?
    }

    public static func mark(for folder: Folder) -> Mark {
        switch folder {
        case .picks: return Mark(rating: 5, label: "Green")
        case .moments: return Mark(rating: 4, label: "Yellow")
        case .review: return Mark(rating: 0, label: nil)
        case .trash: return Mark(rating: -1, label: "Red")
        }
    }

    static let xmpNS = "http://ns.adobe.com/xap/1.0/"
    static let rdfNS = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

    public static func url(for photo: Photo) -> URL {
        photo.primary.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// Writes `mark` into the photo's sidecar, creating it if needed.
    public static func write(_ mark: Mark, for photo: Photo) throws {
        let url = url(for: photo)
        let doc: XMLDocument
        if FileManager.default.fileExists(atPath: url.path) {
            doc = try XMLDocument(contentsOf: url, options: [.nodePreserveAll])
        } else {
            doc = try XMLDocument(xmlString: emptyPacket, options: [])
        }
        guard let description = try doc.nodes(forXPath: "//*[local-name()='Description']").first as? XMLElement else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        if description.resolvePrefix(forNamespaceURI: xmpNS) == nil {
            description.addNamespace(XMLNode.namespace(withName: "xmp", stringValue: xmpNS) as! XMLNode)
        }
        let prefix = description.resolvePrefix(forNamespaceURI: xmpNS) ?? "xmp"
        set(description, "\(prefix):Rating", String(mark.rating))
        set(description, "\(prefix):Label", mark.label)
        try doc.xmlData(options: [.nodePrettyPrint]).write(to: url, options: .atomic)
    }

    /// The mark currently in the photo's sidecar, if any.
    public static func read(for photo: Photo) -> Mark? {
        guard let doc = try? XMLDocument(contentsOf: url(for: photo), options: []),
              let d = (try? doc.nodes(forXPath: "//*[local-name()='Description']"))?.first as? XMLElement
        else { return nil }
        func value(_ name: String) -> String? {
            let prefix = d.resolvePrefix(forNamespaceURI: xmpNS) ?? "xmp"
            return d.attribute(forName: "\(prefix):\(name)")?.stringValue
                ?? d.elements(forLocalName: name, uri: xmpNS).first?.stringValue
        }
        guard let rating = value("Rating").flatMap(Int.init) else { return nil }
        return Mark(rating: rating, label: value("Label"))
    }

    /// Sets an attribute, or the element form some apps write
    /// (`<xmp:Rating>5</xmp:Rating>`) when that's what the file uses.
    private static func set(_ d: XMLElement, _ name: String, _ value: String?) {
        let local = String(name.split(separator: ":").last!)
        let elements = d.elements(forLocalName: local, uri: xmpNS)
        if !elements.isEmpty {
            for e in elements { if let value { e.stringValue = value } else { d.removeChild(at: e.index) } }
            return
        }
        d.removeAttribute(forName: name)
        if let value { d.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
    }

    private static let emptyPacket = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Keepers">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"/>
     </rdf:RDF>
    </x:xmpmeta>
    """
}

// MARK: - Export

public enum Exporter {
    public struct Result {
        public var copied = 0
        public var skipped = 0
    }

    /// Copies every file of `photos` (RAW+JPEG pairs and XMP sidecars too)
    /// into `destination`. An identical file already there is skipped; a
    /// different one with the same name gets a numbered name instead of being
    /// overwritten.
    public static func copy(_ photos: [Photo], to destination: URL,
                            progress: (Int, Int) -> Void = { _, _ in }) throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var files: [URL] = []
        for photo in photos {
            files += photo.files
            let sidecar = XMPSidecar.url(for: photo)
            if fm.fileExists(atPath: sidecar.path) { files.append(sidecar) }
        }
        var result = Result()
        for (i, file) in files.enumerated() {
            try place(file, in: destination, result: &result)
            progress(i + 1, files.count)
        }
        return result
    }

    /// Copies `file` into `destination` unless an identical copy is already
    /// there under its name or a numbered variant of it.
    static func place(_ file: URL, in destination: URL, result: inout Result) throws {
        let target = destination.appendingPathComponent(file.lastPathComponent)
        guard let free = freeName(for: target, identicalTo: file) else { result.skipped += 1; return }
        try FileManager.default.copyItem(at: file, to: free)
        result.copied += 1
    }

    static func sameSize(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        let sa = (try? fm.attributesOfItem(atPath: a.path)[.size]) as? Int
        let sb = (try? fm.attributesOfItem(atPath: b.path)[.size]) as? Int
        return sa != nil && sa == sb
    }

    /// The first free name among `IMG_001.ORF`, `IMG_001 (2).ORF`, … or nil
    /// when one of them already holds an identical copy of `source`.
    static func freeName(for url: URL, identicalTo source: URL) -> URL? {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent(), stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var candidate = url, n = 1
        while fm.fileExists(atPath: candidate.path) {
            if sameSize(source, candidate), fm.contentsEqual(atPath: source.path, andPath: candidate.path) { return nil }
            n += 1
            candidate = dir.appendingPathComponent("\(stem) (\(n))").appendingPathExtension(ext)
        }
        return candidate
    }
}

// MARK: - Memory cards

public enum CardImport {
    public struct Card: Identifiable, Hashable {
        public var id: URL { volume }
        public let volume: URL
        public var name: String { volume.lastPathComponent }
    }

    /// Mounted removable or ejectable volumes with a DCIM folder.
    public static func cards() -> [Card] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter(isCard).map(Card.init)
    }

    public static func isCard(_ volume: URL) -> Bool {
        let values = try? volume.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey])
        guard values?.volumeIsRemovable == true || values?.volumeIsEjectable == true else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: volume.appendingPathComponent("DCIM").path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Supported photo files anywhere under the card's DCIM folder.
    public static func photoFiles(on card: Card) -> [URL] {
        let dcim = card.volume.appendingPathComponent("DCIM")
        guard let walker = FileManager.default.enumerator(at: dcim, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { PhotoFormats.isSupported($0) && !$0.lastPathComponent.hasPrefix("._") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Default destination: `~/Pictures/<date> <card name>`.
    public static func suggestedFolder(for card: Card, date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return pictures.appendingPathComponent("\(f.string(from: date)) \(card.name)", isDirectory: true)
    }

    /// Copies the card's photos into `destination` (flat; cameras number
    /// files uniquely across DCIM subfolders, and clashes get a numbered name).
    public static func importPhotos(from card: Card, to destination: URL,
                                    progress: (Int, Int) -> Void = { _, _ in }) throws -> Exporter.Result {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let files = photoFiles(on: card)
        var result = Exporter.Result()
        for (i, file) in files.enumerated() {
            try Task.checkCancellation()
            try Exporter.place(file, in: destination, result: &result)
            progress(i + 1, files.count)
        }
        return result
    }
}

// MARK: - Sending Trash to the Finder's Trash

extension CullSession {
    /// Moves the originals of `names` (RAW+JPEG pairs and XMP sidecars too)
    /// to the Finder's Trash, where they can be restored, and removes their
    /// links and manual placements. Returns the number of files moved.
    public func moveOriginalsToTrash(_ names: [String]) throws -> Int {
        let fm = FileManager.default
        var moved = 0
        for name in names {
            guard let photo = photos.first(where: { $0.name == name }) else { continue }
            var files = photo.files
            let sidecar = XMPSidecar.url(for: photo)
            if fm.fileExists(atPath: sidecar.path) { files.append(sidecar) }
            for file in files where fm.fileExists(atPath: file.path) {
                try fm.trashItem(at: file, resultingItemURL: nil)
                moved += 1
            }
            for folder in Folder.allCases {
                for file in photo.files {
                    let link = organizer.url(for: folder).appendingPathComponent(photo.linkName(for: file))
                    if FolderOrganizer.isSymlink(link) { try? fm.removeItem(at: link) }
                }
            }
            if store.placements[name] != nil { try store.setPlacement(nil, for: name) }
        }
        return moved
    }

    /// Total size of the originals of `names`, in bytes.
    public func size(of names: [String]) -> Int64 {
        let set = Set(names)
        return photos.filter { set.contains($0.name) }.flatMap(\.files).reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
