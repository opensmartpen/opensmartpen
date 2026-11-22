import Foundation

/// One physical copy of a notebook, as its own folder records it in `books/<name>/book.json`.
///
/// That file is the only authority on what this copy is called and where its printed page numbers
/// start. The folder name carries the surface identity so a person can read it, but nothing may be
/// derived from the name: `book.json` is read instead (ADR-002).
public struct BookRecord: Equatable {
    /// Where this copy lives. Its id is opaque and permanent.
    public let folder: BookFolder
    /// The surface identity the client reported, `s{section}/o{owner}/b{book}` for the pen.
    /// It names a product, so several copies can share it.
    public var surface: String { folder.surface }
    public var title: String
    /// Ncode page number of the notebook's first sheet. Ncode does not start at one.
    public let firstPage: Int
    /// Paper size in millimetres, when it has been recorded.
    public var widthMM: Double?
    public var heightMM: Double?
    /// Loose sheets or facing pages. Decides how the viewer shows it.
    public var binding: KnownBooks.Binding = .pad
    /// Epoch milliseconds at which this copy began. Zero for the first copy of a product, which
    /// has no beginning we witnessed.
    public var startedAt: Int = 0
    /// Which signal decided this was a new copy, so a person who disagrees can see what the app
    /// saw. Nil for the first copy, which was not decided — it was simply the first.
    public var decidedBy: CopySignal?

    public init(folder: BookFolder, title: String, firstPage: Int,
                widthMM: Double? = nil, heightMM: Double? = nil,
                binding: KnownBooks.Binding = .pad,
                startedAt: Int = 0, decidedBy: CopySignal? = nil) {
        self.folder = folder
        self.title = title
        self.firstPage = firstPage
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.binding = binding
        self.startedAt = startedAt
        self.decidedBy = decidedBy
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

    /// The sheet to draw on. Falls back to A4 so a notebook with no recorded size still renders.
    public var geometry: PageGeometry {
        guard let widthMM, let heightMM else { return .a4 }
        return PageGeometry(widthMM: widthMM, heightMM: heightMM)
    }

    /// The paper's proportions, for the small mark beside a page in the panel.
    public var shape: KnownBooks.Shape { KnownBooks.Shape(widthMM: widthMM, heightMM: heightMM) }

    /// The number a person would count to, 1 for the first sheet.
    public func humanPage(_ ncodePage: Int) -> Int { ncodePage - firstPage + 1 }

    /// Readable-file stem. The same name the client
    /// used, so one sheet is one name everywhere under this copy (ADR-002).
    public func pageStem(_ ncodePage: Int) -> String { "p\(ncodePage)" }

    private struct Payload: Codable {
        var surface: String?
        /// What the surface identity was called before ADR-002. Read, never written.
        var id: String?
        var title: String?
        var first_page: Int?
        var width_mm: Double?
        var height_mm: Double?
        var binding: String?
        var started_at: Int?
        var decided_by: String?
    }

    public var json: Data {
        let payload = Payload(surface: surface, id: nil, title: title, first_page: firstPage,
                              width_mm: widthMM, height_mm: heightMM,
                              binding: binding.rawValue,
                              started_at: startedAt,
                              decided_by: decidedBy?.rawValue)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(payload)) ?? Data()
    }

    /// Nil for a file that is not a book record, so a stray JSON file cannot break the panel.
    public init?(folder: BookFolder, json: Data) {
        guard let p = try? JSONDecoder().decode(Payload.self, from: json) else { return nil }
        self.init(folder: folder,
                  title: p.title ?? folder.surface,
                  firstPage: p.first_page ?? 1,
                  widthMM: p.width_mm, heightMM: p.height_mm,
                  // A record written before binding existed does not say. Recognised products
                  // know their own answer, so an old file gets it right without being edited.
                  binding: p.binding.flatMap(KnownBooks.Binding.init(rawValue:))
                      ?? KnownBooks.product(forSurface: folder.surface)?.binding ?? .pad,
                  startedAt: p.started_at ?? 0,
                  decidedBy: p.decided_by.flatMap(CopySignal.init(rawValue:)))
    }
}

/// Every notebook copy on disk, under `books/`. Reloaded when a record changes, so renaming a
/// notebook shows up in the panel without restarting Open Smart Pen.
///
/// Keyed by surface identity, and a surface identity can hold several copies — that is the whole
/// point of ADR-002. The copy in use is the one that began last.
public final class BookRegistry {
    private let root: URL
    private var bySurface: [String: [BookRecord]] = [:]
    private var loadedStamp: Stamp?
    /// Decides whether writing has moved into a fresh physical copy. Lives here because this is
    /// what knows what a book is.
    public let copyWatcher = CopyWatcher()

    public init(root: URL) {
        self.root = root
        reloadIfNeeded()
    }

    /// Every copy of every notebook.
    public var books: [BookRecord] { bySurface.values.flatMap { $0 } }

    /// The copy being written in now: the one that began last.
    public func current(for surface: String) -> BookRecord? {
        reloadIfNeeded()
        return bySurface[surface]?.last
    }

    /// Every copy of one product, oldest first.
    public func copies(of surface: String) -> [BookRecord] {
        reloadIfNeeded()
        return bySurface[surface] ?? []
    }

    /// The copy a page belongs to right now. A page that arrives goes to the newest copy, because
    /// the decision that a copy is new has already been taken by the time a stroke is filed.
    public func record(for page: PageID) -> BookRecord? { current(for: page.surface) }

    public func record(for ref: PageRef) -> BookRecord? {
        reloadIfNeeded()
        return bySurface[ref.folder.surface]?.first { $0.folder == ref.folder }
    }

    /// How a page is named in the interface. An unknown book falls back to its product name:
    /// meaningless, but never misleading — unlike the raw Ncode page index, which is not the
    /// number printed on the sheet.
    public func label(for ref: PageRef) -> PageLabel {
        guard let book = record(for: ref) else {
            // Never the raw book number: that is a product code, and a person neither knows nor
            // should have to know what 3017 means.
            let title = KnownBooks.product(forSurface: ref.folder.surface)?.title ?? "New notebook"
            return PageLabel(title: title, detail: nil)
        }
        return PageLabel(title: book.title, detail: "page \(book.humanPage(ref.page.page))")
    }

    // MARK: - Making copies

    /// Make a record for a book we have not seen before, so its pages stop being anonymous and
    /// start being rendered. Recognised products name and measure themselves; anything else gets
    /// a name from its paper size, which is something a person can see.
    ///
    /// Deliberately silent: writing is never interrupted to ask a question (ADR-002). The record
    /// appears in the panel, where it can be renamed at leisure.
    @discardableResult
    public func ensureRecord(for page: PageID) -> BookRecord? {
        if let existing = current(for: page.surface) { return existing }
        return make(surface: page.surface, startedAt: 0, decidedBy: nil)
    }

    /// Record that writing has moved into a fresh physical copy. Everything written from now goes
    /// to the new folder; everything before it stays exactly where it is, because a page is filed
    /// when it arrives and nothing behind it moves on its own.
    @discardableResult
    public func startNewCopy(of surface: String, at ms: Int, because signal: CopySignal) -> BookRecord? {
        let record = make(surface: surface, startedAt: ms, decidedBy: signal)
        if let record {
            Log.info("new copy of \(surface) as \(record.folder.name), decided by \(signal.rawValue)")
        }
        return record
    }

    private func make(surface: String, startedAt: Int, decidedBy: CopySignal?) -> BookRecord? {
        let known = KnownBooks.product(forSurface: surface)
        let width = known.flatMap(\.widthMM)
        let height = known.flatMap(\.heightMM)
        let folder = BookFolder(surface: surface, id: BookFolder.generateID(taken: takenIDs()))
        let record = BookRecord(folder: folder,
                                title: known?.title ?? KnownBooks.fallbackTitle(widthMM: width, heightMM: height),
                                firstPage: known?.firstPage ?? 1,
                                widthMM: width, heightMM: height,
                                binding: known?.binding ?? .pad,
                                startedAt: startedAt, decidedBy: decidedBy)
        guard save(record) else { return nil }
        // The paper, by the code printed on it: a product, not a person's notebook. Whether the
        // app knew the product says which papers people use that it has no size for.
        var attributes: [String: TelemetryValue] = [
            "book.surface": .string(surface),
            "book.known": .bool(known != nil),
            "book.copies": .int(copies(of: surface).count),
        ]
        if let decidedBy { attributes["book.copy_signal"] = .string(decidedBy.rawValue) }
        Telemetry.event("book.added", attributes)
        return record
    }

    /// Write a record back. The title is free to change and nothing moves, because the folder is
    /// named by an id that means nothing (ADR-002).
    @discardableResult
    public func save(_ record: BookRecord) -> Bool {
        let file = root.appendingPathComponent(record.folder.recordPath)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try record.json.write(to: file, options: .atomic)
            loadedStamp = nil
            reloadIfNeeded()
            return true
        } catch {
            Log.error("writing \(record.folder.recordPath) failed: \(error)")
            return false
        }
    }

    /// Ids already in use, so a generated one cannot land on a folder restored from a backup.
    private func takenIDs() -> Set<String> {
        Set(folderNames().compactMap { BookFolder(name: $0)?.id })
    }

    // MARK: - Files

    /// Where a page's captured strokes live.
    public func rawFile(for ref: PageRef) -> URL {
        root.appendingPathComponent(ref.rawRelativePath)
    }

    /// The readable page, if the processing side has produced one yet. Prefers the PNG, which is
    /// what Preview and Quick Look open happily; falls back to the SVG, then the Markdown.
    public func derivedFile(for ref: PageRef) -> URL? {
        guard let book = record(for: ref) else { return nil }
        let stem = book.pageStem(ref.page.page)
        for ext in ["png", "svg", "md"] {
            let url = root.appendingPathComponent(ref.folder.pagePath(stem: stem, ext: ext))
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Pages most recently written to, newest first, by captured file modification time.
    public func recentPages(limit: Int = 4) -> [(page: PageRef, written: Date)] {
        var found: [(PageRef, Date)] = []
        for name in folderNames() {
            guard let folder = BookFolder(name: name) else { continue }
            let dir = root.appendingPathComponent(folder.relativePath).appendingPathComponent("raw")
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            for url in files where url.pathExtension == "jsonl" {
                let relative = "\(folder.relativePath)/raw/\(url.lastPathComponent)"
                guard let ref = PageRef(rawRelativePath: relative) else { continue }
                let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                found.append((ref, written))
            }
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map { (page: $0.0, written: $0.1) }
    }

    // MARK: - Deleting

    /// Each file of one copy, relative to the notes folder: all that is under its folder, and
    /// the transcript of each page. The bucket has them under the same names, and that is how
    /// they are deleted there: the app does not list a bucket.
    public func files(of folder: BookFolder) -> [String] {
        let own = S3Sync.files(under: folder.relativePath, in: root)
        return own + own.compactMap(PageRef.init(rawRelativePath:)).map(TranscriptStore.path(for:))
    }

    /// How many pages one copy has.
    public func pageCount(of folder: BookFolder) -> Int {
        files(of: folder).filter { $0.hasPrefix("transcripts/") }.count
    }

    /// Remove one copy from this Mac: its folder, and the transcripts kept for it. This cannot
    /// be undone.
    ///
    /// When the copy in use is deleted and an older copy of the same paper stays, a new and
    /// empty copy begins. Without it the next page on that paper would go into the older copy,
    /// among pages it does not belong to.
    public func delete(_ folder: BookFolder) throws {
        let copies = copies(of: folder.surface)
        let wasInUse = copies.last?.folder == folder && copies.count > 1
        for path in [folder.relativePath, "transcripts/\(folder.name)"] {
            let url = root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        loadedStamp = nil
        reloadIfNeeded()
        copyWatcher.forget(folder.surface)
        if wasInUse {
            _ = make(surface: folder.surface, startedAt: Int(Date().timeIntervalSince1970 * 1000), decidedBy: nil)
        }
    }

    // MARK: - Loading

    private func folderNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("books").path)) ?? [])
            .filter { !$0.hasPrefix(".") }
    }

    private func reloadIfNeeded() {
        let files = folderNames()
            .compactMap { BookFolder(name: $0) }
            .map { (folder: $0, url: root.appendingPathComponent($0.recordPath)) }

        // Stamped from the record files themselves, not the directory: editing a record in place
        // leaves the directory's own timestamp untouched, so watching that would miss a rename.
        let stamp = files.reduce(into: Stamp(count: files.count, newest: .distantPast)) { stamp, entry in
            let modified = (try? entry.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            stamp.newest = max(stamp.newest, modified)
        }
        if stamp == loadedStamp { return }
        loadedStamp = stamp

        bySurface = [:]
        for entry in files {
            guard let data = try? Data(contentsOf: entry.url),
                  let record = BookRecord(folder: entry.folder, json: data) else { continue }
            bySurface[record.surface, default: []].append(record)
        }
        // The copy in use is the one that began last, so this order answers that question and is
        // not a presentation choice. The folder name breaks a tie, which only two copies begun in
        // the same millisecond can produce.
        for key in bySurface.keys {
            bySurface[key]?.sort { ($0.startedAt, $0.folder.name) < ($1.startedAt, $1.folder.name) }
        }
    }

    private struct Stamp: Equatable {
        var count: Int
        var newest: Date
    }
}
