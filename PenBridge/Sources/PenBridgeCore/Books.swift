import Foundation

/// A notebook as the notes repo records it, in `books/<slug>.json`. That file is the single
/// source for what a notebook is called and where its printed page numbers start; PenBridge
/// reads it rather than keeping its own copy, so the panel and the processing side can never
/// disagree about which page you are looking at.
public struct BookRecord: Equatable {
    public let slug: String
    /// Ncode identity, `s{section}/o{owner}/b{book}` — matches `PageID.bookKey`.
    public let id: String
    public let title: String
    /// Ncode page number of the notebook's first sheet. Ncode does not start at one.
    public let firstPage: Int
    /// Paper size in millimetres, when the repo recorded it.
    public let widthMM: Double?
    public let heightMM: Double?

    public init(slug: String, id: String, title: String, firstPage: Int,
                widthMM: Double? = nil, heightMM: Double? = nil) {
        self.slug = slug
        self.id = id
        self.title = title
        self.firstPage = firstPage
        self.widthMM = widthMM
        self.heightMM = heightMM
    }

    /// The sheet to draw on. Falls back to A4 so a notebook with no recorded size still renders.
    public var geometry: PageGeometry {
        guard let widthMM, let heightMM else { return .a4 }
        return PageGeometry(widthMM: widthMM, heightMM: heightMM)
    }

    /// The number a person would count to, 1 for the first sheet.
    public func humanPage(_ ncodePage: Int) -> Int { ncodePage - firstPage + 1 }

    /// Derived file stem, matching what `pipeline/books.py` writes.
    public func pageStem(_ ncodePage: Int) -> String {
        String(format: "page-%02d", humanPage(ncodePage))
    }

    private struct Payload: Decodable {
        let id: String
        let title: String?
        let first_page: Int?
        let width_mm: Double?
        let height_mm: Double?
    }

    /// Nil for a file that is not a book record, so a stray JSON file cannot break the panel.
    public init?(slug: String, json: Data) {
        guard let p = try? JSONDecoder().decode(Payload.self, from: json) else { return nil }
        self.init(slug: slug, id: p.id, title: p.title ?? slug, firstPage: p.first_page ?? 1,
                  widthMM: p.width_mm, heightMM: p.height_mm)
    }
}

/// Every notebook the repo knows, keyed by Ncode book. Reloaded when `books/` changes, so
/// renaming a notebook shows up in the panel without restarting PenBridge.
public final class BookRegistry {
    private let repo: URL
    private var byBookKey: [String: BookRecord] = [:]
    private var loadedStamp: Stamp?

    public init(repo: URL) {
        self.repo = repo
        reloadIfNeeded()
    }

    public var books: [BookRecord] { Array(byBookKey.values) }

    public func record(for page: PageID) -> BookRecord? {
        reloadIfNeeded()
        return byBookKey[page.bookKey]
    }

    /// How a page is named in the interface. An unknown book falls back to its product number:
    /// meaningless, but never misleading — unlike the raw Ncode page index, which is not the
    /// number printed on the sheet.
    public func label(for page: PageID) -> PageLabel {
        guard let book = record(for: page) else {
            return PageLabel(title: "Notebook \(page.book)", detail: nil)
        }
        return PageLabel(title: book.title, detail: "page \(book.humanPage(page.page))")
    }

    /// The rendered page, if the processing side has produced one yet. Prefers the PNG, which is
    /// what Preview and Quick Look open happily; falls back to the SVG, then to the raw file so
    /// there is always something to show.
    public func derivedFile(for page: PageID) -> URL? {
        guard let book = record(for: page) else { return nil }
        let dir = repo.appendingPathComponent("pages/\(book.slug)")
        for ext in ["png", "svg", "md"] {
            let url = dir.appendingPathComponent("\(book.pageStem(page.page)).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Where a page's raw strokes live.
    public func rawFile(for page: PageID) -> URL {
        repo.appendingPathComponent(page.rawRelativePath)
    }

    /// Pages most recently written to, newest first, by raw file modification time.
    public func recentPages(limit: Int = 4) -> [(page: PageID, written: Date)] {
        let rawRoot = repo.appendingPathComponent("raw")
        guard let walker = FileManager.default.enumerator(
            at: rawRoot, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var found: [(PageID, Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            // Built from the last five components rather than by stripping the repo prefix:
            // the same directory can be reached as /var/… or /private/var/… and a string
            // comparison silently yields nothing.
            let relative = url.pathComponents.suffix(5).joined(separator: "/")
            guard let page = PageID(rawRelativePath: relative) else { continue }
            let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            found.append((page, written))
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map { (page: $0.0, written: $0.1) }
    }

    private func reloadIfNeeded() {
        let dir = repo.appendingPathComponent("books")
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }

        // Stamped from the files themselves, not the directory: editing a book record in place
        // leaves the directory's own timestamp untouched, so watching that would miss a rename.
        let stamp = files.reduce(into: Stamp(count: files.count, newest: .distantPast)) { stamp, file in
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            stamp.newest = max(stamp.newest, modified)
        }
        if stamp == loadedStamp { return }
        loadedStamp = stamp

        byBookKey = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let record = BookRecord(slug: file.deletingPathExtension().lastPathComponent,
                                          json: data) else { continue }
            byBookKey[record.id] = record
        }
    }

    private struct Stamp: Equatable {
        var count: Int
        var newest: Date
    }
}
