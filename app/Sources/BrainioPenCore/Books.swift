import Foundation

/// A notebook as the notes repo records it, in `books/<slug>.json`. That file is the single
/// source for what a notebook is called and where its printed page numbers start; Brainio Pen
/// reads it rather than keeping its own copy, so the panel and the processing side can never
/// disagree about which page you are looking at.
public struct BookRecord: Equatable {
    public let slug: String
    /// Ncode identity, `s{section}/o{owner}/b{book}` — matches `PageID.bookKey`.
    public let id: String
    public var title: String
    /// Ncode page number of the notebook's first sheet. Ncode does not start at one.
    public let firstPage: Int
    /// Paper size in millimetres, when the repo recorded it.
    public let widthMM: Double?
    public let heightMM: Double?
    /// Physical copies of this product, oldest first. Empty means one copy and no boundaries —
    /// which is every notebook until a second of the same model turns up.
    public var instances: [BookInstance] = []
    /// Loose sheets or facing pages. Decides how the viewer shows it.
    public var binding: KnownBooks.Binding = .pad

    public init(slug: String, id: String, title: String, firstPage: Int,
                widthMM: Double? = nil, heightMM: Double? = nil,
                instances: [BookInstance] = [], binding: KnownBooks.Binding = .pad) {
        self.slug = slug
        self.id = id
        self.title = title
        self.firstPage = firstPage
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.instances = instances
        self.binding = binding
    }

    /// The pages that face each other when this notebook falls open at `page`.
    ///
    /// Page 1 is a right-hand page, as it is in every bound book: you open the cover and one sheet
    /// faces you. So the spreads are (—,1), (2,3), (4,5), and a page's partner is the one that
    /// shares its spread. A pad has no partner at all.
    public func spread(containing humanPage: Int) -> (left: Int?, right: Int?) {
        guard binding == .bound else { return (nil, humanPage) }
        if humanPage <= 1 { return (nil, 1) }
        return humanPage.isMultiple(of: 2) ? (humanPage, humanPage + 1) : (humanPage - 1, humanPage)
    }

    /// The directory a page written at this moment belongs in. With no instances recorded this is
    /// simply the slug, so nothing changes for a notebook there is only one of.
    public func directory(at ms: Int) -> String {
        instances.last(where: { $0.startedAt <= ms })?.slug ?? slug
    }

    /// The sheet to draw on. Falls back to A4 so a notebook with no recorded size still renders.
    public var geometry: PageGeometry {
        guard let widthMM, let heightMM else { return .a4 }
        return PageGeometry(widthMM: widthMM, heightMM: heightMM)
    }

    /// The paper's proportions, for the small mark beside a page in the panel.
    public var shape: KnownBooks.Shape { KnownBooks.Shape(widthMM: widthMM, heightMM: heightMM) }

    /// The number a person would count to, 1 for the first sheet.
    public func humanPage(_ ncodePage: Int) -> Int { ncodePage - firstPage + 1 }

    /// Derived file stem, matching what `pipeline/books.py` writes.
    public func pageStem(_ ncodePage: Int) -> String {
        String(format: "page-%02d", humanPage(ncodePage))
    }

    private struct Payload: Codable {
        let id: String
        let title: String?
        let first_page: Int?
        let width_mm: Double?
        let height_mm: Double?
        var instances: [BookInstance]?
        var binding: String?
    }

    public var json: Data {
        let payload = Payload(id: id, title: title, first_page: firstPage,
                              width_mm: widthMM, height_mm: heightMM,
                              instances: instances.isEmpty ? nil : instances,
                              binding: binding.rawValue)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(payload)) ?? Data()
    }

    /// Nil for a file that is not a book record, so a stray JSON file cannot break the panel.
    public init?(slug: String, json: Data) {
        guard let p = try? JSONDecoder().decode(Payload.self, from: json) else { return nil }
        self.init(slug: slug, id: p.id, title: p.title ?? slug, firstPage: p.first_page ?? 1,
                  widthMM: p.width_mm, heightMM: p.height_mm, instances: p.instances ?? [],
                  // A record written before binding existed does not say. Recognised products
                  // know their own answer, so an old file gets it right without being edited.
                  binding: p.binding.flatMap(KnownBooks.Binding.init(rawValue:))
                      ?? KnownBooks.product(forBookKey: p.id)?.binding ?? .pad)
    }
}

/// Every notebook the repo knows, keyed by Ncode book. Reloaded when `books/` changes, so
/// renaming a notebook shows up in the panel without restarting Brainio Pen.
public final class BookRegistry {
    private let repo: URL
    private var byBookKey: [String: BookRecord] = [:]
    private var loadedStamp: Stamp?
    /// Watches for a second physical copy of a notebook. Lives here because this is what knows
    /// what a book is.
    public let instanceWatcher = InstanceWatcher()

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
            // Never the raw book number: that is a product code, and a person neither knows nor
            // should have to know what 3017 means.
            let title = KnownBooks.product(forBookKey: page.bookKey)?.title ?? "New notebook"
            return PageLabel(title: title, detail: nil)
        }
        return PageLabel(title: book.title, detail: "page \(book.humanPage(page.page))")
    }

    /// Make a record for a book we have not seen before, so its pages stop being anonymous and
    /// start being rendered. Recognised products name and measure themselves; anything else gets
    /// a name from its paper size, which is something a person can see.
    ///
    /// Deliberately silent: writing is never interrupted to ask a question. The provisional record
    /// appears in the panel, where it can be renamed at leisure.
    @discardableResult
    public func ensureRecord(for page: PageID) -> BookRecord? {
        if let existing = record(for: page) { return existing }
        let known = KnownBooks.product(forBookKey: page.bookKey)
        let width = known.flatMap(\.widthMM)
        let height = known.flatMap(\.heightMM)
        let title = known?.title ?? KnownBooks.fallbackTitle(widthMM: width, heightMM: height)
        let record = BookRecord(slug: uniqueSlug(from: title), id: page.bookKey, title: title,
                                firstPage: known?.firstPage ?? 1,
                                widthMM: width, heightMM: height,
                                binding: known?.binding ?? .pad)
        return save(record) ? record : nil
    }

    /// Write a record back. The title is free to change; the slug is not, because it is also the
    /// name of the directory every rendered page lives in.
    @discardableResult
    public func save(_ record: BookRecord) -> Bool {
        let dir = repo.appendingPathComponent("books")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try record.json.write(to: dir.appendingPathComponent("\(record.slug).json"), options: .atomic)
            loadedStamp = nil
            reloadIfNeeded()
            return true
        } catch {
            Log.error("writing books/\(record.slug).json failed: \(error)")
            return false
        }
    }

    /// A free filename. Two pads of the same model are a real case, so a suffix is expected here
    /// rather than exceptional.
    private func uniqueSlug(from title: String) -> String {
        let base = PenRecord.slug(from: title, mac: "book")
        let taken = Set(((try? FileManager.default.contentsOfDirectory(
            atPath: repo.appendingPathComponent("books").path)) ?? [])
            .map { ($0 as NSString).deletingPathExtension })
        if !taken.contains(base) { return base }
        for n in 2...99 where !taken.contains("\(base)-\(n)") { return "\(base)-\(n)" }
        return "\(base)-\(Int(Date().timeIntervalSince1970))"
    }

    /// The rendered page, if the processing side has produced one yet. Prefers the PNG, which is
    /// what Preview and Quick Look open happily; falls back to the SVG, then to the raw file so
    /// there is always something to show.
    public func derivedFile(for page: PageID) -> URL? {
        guard let book = record(for: page) else { return nil }
        let written = (try? rawFile(for: page).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let dir = repo.appendingPathComponent(
            "pages/\(book.directory(at: Int(written.timeIntervalSince1970 * 1000)))")
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

    /// The question was answered, either way.
    public func resolveInstanceQuestion(_ bookKey: String) {
        instanceWatcher.resolve(book: bookKey)
    }

    /// Record that a fresh physical copy of this notebook was opened at this moment. The boundary
    /// is a date, and every stroke carries one, so this can be applied long after the fact and
    /// everything downstream re-derives.
    @discardableResult
    public func startInstance(of book: BookRecord, at ms: Int) -> BookRecord? {
        var updated = book
        // The first copy is implicit until there is a second: recording only the new boundary
        // would leave every earlier page with nowhere to go.
        if updated.instances.isEmpty {
            updated.instances = [BookInstance(slug: book.slug, startedAt: 0)]
        }
        let next = updated.instances.count + 1
        updated.instances.append(BookInstance(slug: "\(book.slug)-\(next)", startedAt: ms))
        return save(updated) ? updated : nil
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
