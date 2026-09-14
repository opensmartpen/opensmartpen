import XCTest
@testable import BrainioPenCore

/// Routing is where "we decide a new copy ourselves, and we never ask" actually happens, and it
/// has to happen before a stroke is written: a stroke in the wrong copy cannot be moved out of the
/// file it landed in without cutting that file (ADR-002).
final class RouterTests: XCTestCase {
    private var root: URL!
    private var store: RawStore!
    private var books: BookRegistry!
    private var router: PageRouter!
    private let pad = "s3/o27/b450"
    private let day = 86_400_000

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = RawStore(root: root, app: "c", sdk: "s")
        books = BookRegistry(root: root)
        router = PageRouter(books: books, store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A line of writing across a page, offset so two calls with different `at` do not look alike.
    private func strokes(page: Int, at ms: Int, x: Double = 10) -> [Stroke] {
        let id = PageID(section: 3, owner: 27, book: 450, page: page)
        return [Stroke(page: id, start: ms, end: ms + 100,
                       dots: (0..<20).map { DotSample(x: x + Double($0), y: 20, force: 0.5, dt: 12) },
                       source: .live, penMac: "M", firmware: "F")]
    }

    private func write(page: Int, at ms: Int, x: Double = 10) throws {
        for group in router.route(strokes(page: page, at: ms, x: x)) {
            try store.append(group.strokes, to: group.folder)
        }
    }

    func testTheFirstStrokeOpensTheOnlyCopy() throws {
        try write(page: 1, at: 0)
        XCTAssertEqual(books.copies(of: pad).count, 1)
        XCTAssertNil(books.current(for: pad)?.decidedBy, "the first copy was not decided")
    }

    func testOrdinaryWritingStaysInOneCopy() throws {
        for page in 1...5 { try write(page: page, at: page * day) }
        XCTAssertEqual(books.copies(of: pad).count, 1)
        XCTAssertEqual(store.pages(in: try XCTUnwrap(books.current(for: pad)).folder).sorted(), [1, 2, 3, 4, 5])
    }

    func testWritingOverTheSamePageOpensASecondCopy() throws {
        try write(page: 1, at: 0)
        // The same sheet, written on again in the same place. One sheet cannot hold that twice.
        try write(page: 1, at: 2 * day)

        XCTAssertEqual(books.copies(of: pad).count, 2)
        let copies = books.copies(of: pad)
        XCTAssertEqual(copies.last?.decidedBy, .inkOverlap)
        XCTAssertEqual(store.pages(in: copies[0].folder), [1])
        XCTAssertEqual(store.pages(in: copies[1].folder), [1], "each copy has its own page 1")
    }

    func testTheTwoCopiesOfOnePageAreSeparateFiles() throws {
        try write(page: 1, at: 0)
        try write(page: 1, at: 2 * day)
        let copies = books.copies(of: pad)
        let first = try String(contentsOf: store.fileURL(for: PageRef(folder: copies[0].folder,
            page: PageID(section: 3, owner: 27, book: 450, page: 1))), encoding: .utf8)
        let second = try String(contentsOf: store.fileURL(for: PageRef(folder: copies[1].folder,
            page: PageID(section: 3, owner: 27, book: 450, page: 1))), encoding: .utf8)
        XCTAssertEqual(first.split(separator: "\n").count, 2, "meta + one stroke")
        XCTAssertEqual(second.split(separator: "\n").count, 2, "and not three in one file")
    }

    func testAnnotatingBesideOldInkStaysInTheSameCopy() throws {
        try write(page: 1, at: 0, x: 10)
        // A line added well clear of the first one — the ordinary case of coming back to a page.
        try write(page: 1, at: 2 * day, x: 60)
        XCTAssertEqual(books.copies(of: pad).count, 1)
    }

    func testStartingAgainAtTheFrontAfterASilenceOpensASecondCopy() throws {
        for page in 1...14 { try write(page: page, at: page * 1000) }
        try write(page: 1, at: 3 * day, x: 60)   // clear of the old ink, so overlap decides nothing
        XCTAssertEqual(books.copies(of: pad).count, 2)
        XCTAssertEqual(books.copies(of: pad).last?.decidedBy, .sequenceRestart)
    }

    func testStrokesLandInTheCopyThatWasDecidedForThem() throws {
        try write(page: 1, at: 0)
        try write(page: 1, at: 2 * day)
        let copies = books.copies(of: pad)
        // Everything written after the boundary goes to the new copy, and nothing behind it moves.
        try write(page: 2, at: 3 * day)
        XCTAssertEqual(store.pages(in: copies[0].folder), [1])
        XCTAssertEqual(store.pages(in: copies[1].folder).sorted(), [1, 2])
    }

    func testWhatIsOnDiskIsAdoptedSoARestartIsNotAFreshNotebook() throws {
        for page in 1...14 { try write(page: page, at: page * 1000) }

        // A new process: a new registry, a new store, a new watcher with no memory.
        let store2 = RawStore(root: root, app: "c", sdk: "s")
        let books2 = BookRegistry(root: root)
        let router2 = PageRouter(books: books2, store: store2)
        router2.adoptExisting()

        XCTAssertEqual(books2.copies(of: pad).count, 1, "adopting decides nothing on its own")
        for group in router2.route(strokes(page: 15, at: 15_000, x: 60)) {
            try store2.append(group.strokes, to: group.folder)
        }
        XCTAssertEqual(books2.copies(of: pad).count, 1, "carrying on where you stopped is one notebook")
    }

    /// The pen sends the stroke in progress at connection time both from its memory and live, and
    /// a whole notebook again when a drain is retried. A re-delivered stroke lands on its own ink
    /// exactly, so judging it as new writing reads every drain as a second pad written over the
    /// first — which is what happened on a real Mac: one A4 pad became five.
    func testARedeliveredStrokeIsNotASecondNotebook() throws {
        let first = strokes(page: 1, at: 0)
        for group in router.route(first) { try store.append(group.strokes, to: group.folder) }

        // The same strokes again, a few milliseconds off, as an offline drain delivers them.
        var again = first
        again[0].id = UUID()
        again[0].start -= 23
        again[0].source = .offline
        for group in router.route(again) { try store.append(group.strokes, to: group.folder) }

        XCTAssertEqual(books.copies(of: pad).count, 1, "the same writing arriving twice is one notebook")
        let file = store.fileURL(for: PageRef(folder: try XCTUnwrap(books.current(for: pad)).folder,
                                              page: PageID(section: 3, owner: 27, book: 450, page: 1)))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count, 2,
                       "meta + one stroke: the duplicate is dropped, not filed in a copy of its own")
    }

    /// A whole page re-delivered — every stroke of it — is the case that actually bit.
    func testAWholePageRedeliveredIsNotASecondNotebook() throws {
        var batch: [Stroke] = []
        for page in 1...3 { batch += strokes(page: page, at: page * 1000) }
        for group in router.route(batch) { try store.append(group.strokes, to: group.folder) }

        for _ in 1...4 {
            var drain = batch
            for i in drain.indices { drain[i].id = UUID(); drain[i].source = .offline }
            for group in router.route(drain) { try store.append(group.strokes, to: group.folder) }
        }
        XCTAssertEqual(books.copies(of: pad).count, 1, "four retried drains are still one pad")
    }

    func testTwoProductsAreRoutedApartInOneBatch() throws {
        let lamy = PageID(section: 3, owner: 1012, book: 3017, page: 4)
        let mixed = strokes(page: 1, at: 0) + [
            Stroke(page: lamy, start: 10, end: 20,
                   dots: [DotSample(x: 1, y: 1, force: 0.5, dt: 0)],
                   source: .live, penMac: "M", firmware: "F")]
        for group in router.route(mixed) { try store.append(group.strokes, to: group.folder) }
        XCTAssertEqual(books.copies(of: pad).count, 1)
        XCTAssertEqual(books.copies(of: "s3/o1012/b3017").count, 1)
    }
}

/// Notes written before ADR-002 sat in one tree keyed by product. They have to arrive in the new
/// layout, and the old repository has to survive the move untouched.
final class MigrationTests: XCTestCase {
    private var old: URL!
    private var new: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-tests-\(UUID().uuidString)")
        old = base.appendingPathComponent("notes")
        new = base.appendingPathComponent("pen")
        try make("books/a4-pad.json", #"{"id":"s3/o27/b450","title":"Desk pad","width_mm":210.0,"height_mm":297.0,"first_page":1}"#)
        try make("raw/s3/o27/b450/p1.jsonl", "{\"t\":\"stroke\"}")
        try make("raw/s3/o27/b450/p2.jsonl", "{\"t\":\"stroke\"}")
        try make("raw/mode.jsonl", "{\"t\":\"mode\"}")
        try make("pages/a4-pad/page-01.svg", "<svg/>")
        try make("palette.json", "{}")
        try make("pens/pen.json", "{}")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: old.deletingLastPathComponent())
    }

    private func make(_ path: String, _ body: String) throws {
        let url = old.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: new.appendingPathComponent(path).path)
    }

    func testEverythingArrivesInTheNewLayout() throws {
        XCTAssertTrue(DataMigration.adoptLegacyRepo(from: old, to: new))
        let books = BookRegistry(root: new)
        let record = try XCTUnwrap(books.current(for: "s3/o27/b450"))
        XCTAssertEqual(record.title, "Desk pad", "the name a person gave it survives")
        XCTAssertEqual(record.widthMM, 210)
        XCTAssertTrue(exists(record.folder.rawPath(page: 1)))
        XCTAssertTrue(exists(record.folder.rawPath(page: 2)))
        XCTAssertTrue(exists(record.folder.pagePath(stem: "page-01", ext: "svg")))
        XCTAssertTrue(exists("mode.jsonl"), "a setting has no surface, so it sits at the root")
        XCTAssertTrue(exists("palette.json"))
        XCTAssertTrue(exists("pens/pen.json"))
    }

    func testTheOldRepositoryIsLeftExactlyAsItWas() throws {
        XCTAssertTrue(DataMigration.adoptLegacyRepo(from: old, to: new))
        for path in ["books/a4-pad.json", "raw/s3/o27/b450/p1.jsonl", "raw/mode.jsonl"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent(path).path),
                          "\(path) was copied, not moved")
        }
    }

    func testRunningItTwiceChangesNothing() throws {
        XCTAssertTrue(DataMigration.adoptLegacyRepo(from: old, to: new))
        let folder = try XCTUnwrap(BookRegistry(root: new).current(for: "s3/o27/b450")).folder
        XCTAssertFalse(DataMigration.adoptLegacyRepo(from: old, to: new), "it is safe on every launch")
        XCTAssertEqual(BookRegistry(root: new).current(for: "s3/o27/b450")?.folder, folder,
                       "and it does not make a second copy of everything")
    }

    func testAPageWhoseBookWasNeverRecordedStillArrives() throws {
        try make("raw/s3/o1012/b3017/p4.jsonl", "{\"t\":\"stroke\"}")
        XCTAssertTrue(DataMigration.adoptLegacyRepo(from: old, to: new))
        let books = BookRegistry(root: new)
        let record = try XCTUnwrap(books.current(for: "s3/o1012/b3017"))
        XCTAssertEqual(record.title, "LAMY notebook", "a product we know on sight names itself")
        XCTAssertTrue(exists(record.folder.rawPath(page: 4)))
    }
}
