import Foundation

/// Puts each arriving stroke into the copy of the notebook it belongs to.
///
/// This is where "we decide a new copy ourselves, and we never ask" is carried out (ADR-002). The
/// decision has to happen before a stroke is written, because writing it into the wrong copy is
/// the mistake that cannot be repaired: two pads interleaved inside one captured file can only be
/// separated by cutting the file, and captured files are never cut.
public final class PageRouter {
    private let books: BookRegistry
    private let store: RawStore

    public init(books: BookRegistry, store: RawStore) {
        self.books = books
        self.store = store
    }

    /// Tell the watcher what is already on disk, so a restart does not read as a fresh notebook
    /// and a silence is measured from the last stroke rather than from launch.
    public func adoptExisting() {
        for book in books.books {
            let pages = store.pages(in: book.folder)
            guard !pages.isEmpty else { continue }
            let dir = store.root.appendingPathComponent(book.folder.relativePath)
                .appendingPathComponent("raw")
            let newest = ((try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate }
                .max() ?? Date()
            books.copyWatcher.adopt(surface: book.surface, pages: pages,
                                    at: Int(newest.timeIntervalSince1970 * 1000))
        }
    }

    /// Group arriving strokes by the copy that should hold them, opening a new copy when the
    /// evidence says the notebook on the desk is a different one.
    public func route(_ strokes: [Stroke]) -> [(folder: BookFolder, strokes: [Stroke])] {
        var out: [BookFolder: [Stroke]] = [:]

        for (surface, forSurface) in Dictionary(grouping: strokes, by: { $0.page.surface }) {
            guard var folder = books.ensureRecord(for: forSurface[0].page)?.folder else {
                Log.error("no book record for \(surface); \(forSurface.count) stroke(s) not filed")
                continue
            }
            // A decision is about a moment, so pages are considered in the order they were
            // written, not the order a drain happened to hand them over.
            let byPage = Dictionary(grouping: forSurface, by: { $0.page.page })
                .sorted { ($0.value.map(\.start).min() ?? 0) < ($1.value.map(\.start).min() ?? 0) }

            for (page, list) in byPage {
                guard let id = PageID(surface: surface, page: page) else { continue }
                let ref = PageRef(folder: folder, page: id)
                let evidence = CopyEvidence(surface: surface, page: page,
                                            at: list.map(\.start).min() ?? 0,
                                            inkOverlap: store.inkOverlap(list, with: ref))
                if let signal = books.copyWatcher.decide(evidence),
                   let fresh = books.startNewCopy(of: surface, at: evidence.at, because: signal) {
                    folder = fresh.folder
                }
                out[folder, default: []].append(contentsOf: list)
            }
        }

        return out.map { (folder: $0.key, strokes: $0.value) }
    }
}
