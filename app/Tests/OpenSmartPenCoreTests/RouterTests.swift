import XCTest
@testable import OpenSmartPenCore

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

    /// Lines of writing across a page, offset so two calls with different `at` do not look alike.
    private func strokes(page: Int, at ms: Int, x: Double = 10, count: Int = 1) -> [Stroke] {
        let id = PageID(section: 3, owner: 27, book: 450, page: page)
        return (0..<count).map { n in
            Stroke(page: id, start: ms + n * 900, end: ms + n * 900 + 100,
                   dots: (0..<20).map { DotSample(x: x + Double($0), y: 20 + Double(n), force: 0.5, dt: 12) },
                   source: .live, penMac: "M", firmware: "F")
        }
    }

    private func write(page: Int, at ms: Int, x: Double = 10, count: Int = 1) throws {
        for group in router.route(strokes(page: page, at: ms, x: x, count: count)) {
            try store.append(group.strokes, to: group.folder)
        }
    }

    /// One sample on a book nobody has, as the pen reports when it wakes against the page or
    /// misreads the pattern for an instant.
    private func speck(surface: (owner: Int, book: Int), page: Int, at ms: Int) -> Stroke {
        Stroke(page: PageID(section: 3, owner: surface.owner, book: surface.book, page: page),
               start: ms, end: ms, dots: [DotSample(x: 395.49, y: 119.42, force: 0.45, dt: 0)],
               source: .live, penMac: "M", firmware: "F")
    }

    /// The failure that put a second, blank "Notebook" in the panel: one dot, decoded to a book
    /// that was never on the desk, opened a folder and a page and was committed.
    func testASpeckOnPaperNeverSeenIsNotANotebook() throws {
        let routed = router.route([speck(surface: (1012, 4041), page: 55, at: 1_000)])
        XCTAssertTrue(routed.isEmpty)
        XCTAssertNil(books.current(for: "s3/o1012/b4041"))
    }

    func testASpeckOnANotebookThatExistsIsKept() throws {
        // A full stop is a speck too, and on a page that is being written it is ink.
        try write(page: 1, at: 0)
        let routed = router.route([speck(surface: (27, 450), page: 1, at: 5_000)])
        XCTAssertEqual(routed.flatMap(\.strokes).count, 1)
    }

    /// The failure that made one A4 pad into five on a real Mac, twice. Handwriting is strokes
    /// landing on other strokes: letters in a word sit closer together than one Ncode cell.
    func testWritingOnOnePageAllAfternoonIsOnePad() throws {
        for n in 0..<200 {
            // Every stroke in the same place, arriving one at a time, as live writing does.
            try write(page: 1, at: 1_000 + n * 800, x: 10)
        }
        XCTAssertEqual(books.copies(of: pad).count, 1)
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
        try write(page: 1, at: 0, count: 40)
        // The same sheet, put down for two days, then written full again in the same places.
        try write(page: 1, at: 2 * day, count: 40)

        XCTAssertEqual(books.copies(of: pad).count, 2)
        let copies = books.copies(of: pad)
        XCTAssertEqual(copies.last?.decidedBy, .inkOverlap)
        XCTAssertEqual(store.pages(in: copies[0].folder), [1])
        XCTAssertEqual(store.pages(in: copies[1].folder), [1], "each copy has its own page 1")
    }

    func testTheTwoCopiesOfOnePageAreSeparateFiles() throws {
        try write(page: 1, at: 0, count: 40)
        try write(page: 1, at: 2 * day, count: 40)
        let copies = books.copies(of: pad)
        let first = try String(contentsOf: store.fileURL(for: PageRef(folder: copies[0].folder,
            page: PageID(section: 3, owner: 27, book: 450, page: 1))), encoding: .utf8)
        let second = try String(contentsOf: store.fileURL(for: PageRef(folder: copies[1].folder,
            page: PageID(section: 3, owner: 27, book: 450, page: 1))), encoding: .utf8)
        XCTAssertEqual(first.split(separator: "\n").count, 41, "meta + one pad's writing")
        XCTAssertEqual(second.split(separator: "\n").count, 41, "and not both pads in one file")
    }

    func testAnnotatingBesideOldInkStaysInTheSameCopy() throws {
        try write(page: 1, at: 0, count: 40)
        // Writing added well clear of it — the ordinary case of coming back to a page.
        try write(page: 1, at: 2 * day, x: 200, count: 40)
        XCTAssertEqual(books.copies(of: pad).count, 1)
    }

    func testStartingAgainAtTheFrontAfterASilenceOpensASecondCopy() throws {
        for page in 1...14 { try write(page: page, at: page * 1000) }
        try write(page: 1, at: 3 * day, x: 60)   // clear of the old ink, so overlap decides nothing
        XCTAssertEqual(books.copies(of: pad).count, 2)
        XCTAssertEqual(books.copies(of: pad).last?.decidedBy, .sequenceRestart)
    }

    func testStrokesLandInTheCopyThatWasDecidedForThem() throws {
        try write(page: 1, at: 0, count: 40)
        try write(page: 1, at: 2 * day, count: 40)
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
        // A stroke of writing, not one sample: a single sample on a book never seen is a speck,
        // and specks open nothing.
        let mixed = strokes(page: 1, at: 0) + [
            Stroke(page: lamy, start: 10, end: 110,
                   dots: (0..<20).map { DotSample(x: 1 + Double($0), y: 1, force: 0.5, dt: 5) },
                   source: .live, penMac: "M", firmware: "F")]
        for group in router.route(mixed) { try store.append(group.strokes, to: group.folder) }
        XCTAssertEqual(books.copies(of: pad).count, 1)
        XCTAssertEqual(books.copies(of: "s3/o1012/b3017").count, 1)
    }
}
