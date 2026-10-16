import AppKit
import KeepersCore

/// Export, XMP ratings, the Finder Trash, and card import.
extension AppModel {
    func export(_ folders: [Folder]) {
        guard let session else { return }
        let photos = items.filter { folders.contains($0.folder) }.map(\.photo)
        guard !photos.isEmpty else {
            show(Notice(title: "Nothing to export", message: "There are no photos in \(folders.map(\.rawValue).joined(separator: " or "))."))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Copy \(photos.count) photo\(photos.count == 1 ? "" : "s") from \(folders.map(\.rawValue).joined(separator: " and ")) to:"
        panel.directoryURL = session.inputDirectory.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        run("Exporting", cancellable: false) { progress in
            let r = try Exporter.copy(photos, to: destination, progress: progress)
            return Notice(title: "Export finished",
                          message: "Copied \(r.copied) file\(r.copied == 1 ? "" : "s")" + (r.skipped > 0 ? "; \(r.skipped) already there." : "."),
                          reveal: destination)
        }
    }

    func writeRatings() {
        let all = items
        let alert = NSAlert()
        alert.messageText = "Write ratings to XMP sidecars?"
        alert.informativeText = """
        Keepers writes a star rating and color label into an .xmp file next to each photo, which Lightroom Classic, \
        Capture One, and Bridge read when importing:

        Top Picks ★★★★★ Green · Moments ★★★★ Yellow · Review no stars, no label · Trash rejected (−1) Red

        Existing sidecars keep their other settings, but their rating and label are replaced. Originals aren't touched.
        """
        alert.addButton(withTitle: "Write \(all.count) Sidecars")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        run("Writing ratings", cancellable: false) { progress in
            var failed = 0
            for (i, item) in all.enumerated() {
                do { try XMPSidecar.write(XMPSidecar.mark(for: item.folder), for: item.photo) } catch { failed += 1 }
                progress(i + 1, all.count)
            }
            return Notice(title: "Ratings written",
                          message: "\(all.count - failed) sidecar\(all.count - failed == 1 ? "" : "s") written" + (failed > 0 ? "; \(failed) failed." : "."))
        }
    }

    func moveTrashToFinderTrash() {
        guard let session else { return }
        let names = self.names[.trash] ?? []
        guard !names.isEmpty else { return }
        let size = ByteCountFormatter.string(fromByteCount: session.size(of: names), countStyle: .file)
        let alert = NSAlert()
        alert.messageText = "Move \(names.count) photo\(names.count == 1 ? "" : "s") to the Finder Trash?"
        alert.informativeText = "The originals in Keepers' Trash folder (\(size)) move to the Finder Trash, with their RAW+JPEG pairs and XMP sidecars. You can put them back from there until it's emptied."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let moved = try session.moveOriginalsToTrash(names)
            show(Notice(title: "Moved to the Trash", message: "\(moved) file\(moved == 1 ? "" : "s") moved to the Finder Trash."))
            start(fresh: false)  // Rescan the folder; the analysis is cached.
        } catch {
            errorMessage = error.localizedDescription
            start(fresh: false)
        }
    }

    func importCard(_ card: CardImport.Card) {
        let count = CardImport.photoFiles(on: card).count
        guard count > 0 else {
            show(Notice(title: "No photos on \(card.name)", message: "Keepers looks for photos in the card's DCIM folder."))
            return
        }
        let suggested = CardImport.suggestedFolder(for: card)
        let panel = NSSavePanel()
        panel.title = "Import \(count) photos from \(card.name)"
        panel.prompt = "Import"
        panel.nameFieldLabel = "New folder:"
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        run("Importing from \(card.name)", cancellable: true) { progress in
            _ = try CardImport.importPhotos(from: card, to: destination, progress: progress)
            return nil
        } then: { [weak self] in
            // Straight into culling the new folder.
            self?.open(destination)
            self?.start(fresh: false)
        }
    }

    func cancelActivity() { activityTask?.cancel() }

    /// Runs `work` off the main thread with progress, then shows its notice.
    private func run(_ title: String, cancellable: Bool,
                     _ work: @escaping @Sendable (_ progress: @escaping (Int, Int) -> Void) throws -> Notice?,
                     then: (@MainActor () -> Void)? = nil) {
        activity = Activity(title: title, cancellable: cancellable)
        activityTask = Task { [weak self] in
            let report: (Int, Int) -> Void = { done, total in
                Task { @MainActor in self?.activity?.done = done; self?.activity?.total = total }
            }
            let job = Task.detached(priority: .userInitiated) { () -> Result<Notice?, Error> in
                Result { try work(report) }
            }
            // Cancel reaches the detached work (card import checks for it).
            let outcome = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self else { return }
            self.activity = nil
            switch outcome {
            case .success(let notice):
                if let notice { self.show(notice) }
                then?()
            case .failure(let error) where error is CancellationError:
                break
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }
}
