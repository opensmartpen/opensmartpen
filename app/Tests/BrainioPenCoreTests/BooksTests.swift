import XCTest
@testable import BrainioPenCore

/// The notes repo's `books/<slug>.json` is the single source for what a notebook is called and
/// where its page numbers start. Brainio Pen reads it rather than keeping a second copy, so these
/// tests use the real file shape that `pipeline/books.py` writes.
final class BooksTests: XCTestCase {
    private var repo: URL!
    private let lamyPage = PageID(section: 3, owner: 1012, book: 3017, page: 15)
    private let padPage = PageID(section: 3, owner: 27, book: 450, page: 3)

    override func setUpWithError() throws {
        repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("books-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("books"),
                                                withIntermediateDirectories: true)
        try write("a4-pad", #"{"id":"s3/o27/b450","title":"Ncode A4 pad","width_mm":210.0,"first_page":1}"#)
        try write("lamy", #"{"id":"s3/o1012/b3017","title":"LAMY notebook","first_page":1}"#)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    private func write(_ slug: String, _ json: String) throws {
        try Data(json.utf8).write(to: repo.appendingPathComponent("books/\(slug).json"))
    }

    func testPagesAreLabelledFromTheRepoRecord() {
        let books = BookRegistry(repo: repo)
        XCTAssertEqual(books.label(for: padPage), PageLabel(title: "Ncode A4 pad", detail: "page 3"))
        XCTAssertEqual(books.label(for: lamyPage).oneLine, "LAMY notebook · page 15")
    }

    func testFirstPageShiftsNcodeOntoThePrintedNumber() throws {
        // A notebook whose first sheet the pen calls page 4.
        try write("offset", #"{"id":"s3/o99/b1","title":"Offset pad","first_page":4}"#)
        let books = BookRegistry(repo: repo)
        let page = PageID(section: 3, owner: 99, book: 1, page: 15)
        XCTAssertEqual(books.label(for: page).detail, "page 12")
        XCTAssertEqual(books.record(for: page)?.pageStem(4), "page-01")
    }

    func testUnknownBookIsNeverNamedAfterItsProductCode() {
        // The book number is a product code. A person does not know what 777 means and should
        // not have to, so it never reaches the interface.
        let books = BookRegistry(repo: repo)
        let stranger = PageID(section: 3, owner: 1, book: 777, page: 9)
        XCTAssertEqual(books.label(for: stranger), PageLabel(title: "New notebook", detail: nil))
    }

    func testARecognisedProductNamesAndMeasuresItself() throws {
        // Nothing in books/ for it yet — this is a notebook meeting Brainio Pen for the first time.
        try FileManager.default.removeItem(at: repo.appendingPathComponent("books/lamy.json"))
        let books = BookRegistry(repo: repo)
        let lamy = PageID(section: 3, owner: 1012, book: 3017, page: 4)
        let record = try XCTUnwrap(books.ensureRecord(for: lamy))
        XCTAssertEqual(record.title, "LAMY notebook")
        XCTAssertEqual(record.widthMM, 145, "a product we know on sight needs no measuring")
        XCTAssertEqual(books.label(for: lamy), PageLabel(title: "LAMY notebook", detail: "page 4"))
    }

    func testAnUnrecognisedBookIsNamedAfterItsPaperNotItsCode() throws {
        let books = BookRegistry(repo: repo)
        let stranger = PageID(section: 3, owner: 1, book: 777, page: 9)
        let record = try XCTUnwrap(books.ensureRecord(for: stranger))
        XCTAssertEqual(record.title, "Notebook")
        XCTAssertFalse(record.slug.contains("777"))
        // Provisional, but real: the page stops being anonymous immediately.
        XCTAssertEqual(books.label(for: stranger).title, "Notebook")
    }

    func testAKnownProductKnowsHowItIsBoundEvenInAnOldRecord() {
        // books/lamy.json was written before binding existed and says nothing about it. The LAMY
        // is a bound notebook, so it must still open as a spread rather than as loose sheets.
        let books = BookRegistry(repo: repo)
        XCTAssertEqual(books.record(for: lamyPage)?.binding, .bound)
        XCTAssertEqual(books.record(for: padPage)?.binding, .pad)
    }

    func testABoundNotebookFallsOpenAtFacingPages() {
        let lamy = BookRecord(slug: "lamy", id: "s3/o1012/b3017", title: "LAMY", firstPage: 1,
                              binding: .bound)
        // Page 1 is a right-hand page, as it is in every bound book: you open the cover and one
        // sheet faces you.
        XCTAssertEqual(lamy.spread(containing: 1).left, nil)
        XCTAssertEqual(lamy.spread(containing: 1).right, 1)
        XCTAssertEqual(lamy.spread(containing: 4).left, 4)
        XCTAssertEqual(lamy.spread(containing: 4).right, 5)
        XCTAssertEqual(lamy.spread(containing: 5).left, 4)
        XCTAssertEqual(lamy.spread(containing: 5).right, 5)

        let pad = BookRecord(slug: "pad", id: "s3/o27/b450", title: "Pad", firstPage: 1)
        XCTAssertEqual(pad.spread(containing: 4).left, nil, "a pad is loose sheets")
    }

    func testTwoUnknownNotebooksDoNotShareADirectory() throws {
        let books = BookRegistry(repo: repo)
        // Both fall back to the same name, and the slug is also the directory every rendered page
        // lands in — so the second one has to give way or it would overwrite the first.
        let first = try XCTUnwrap(books.ensureRecord(for: PageID(section: 3, owner: 1, book: 777, page: 1)))
        let second = try XCTUnwrap(books.ensureRecord(for: PageID(section: 3, owner: 1, book: 778, page: 1)))
        XCTAssertEqual(first.title, second.title)
        XCTAssertNotEqual(first.slug, second.slug)
    }

    func testRenamingANotebookIsPickedUpWithoutRestarting() throws {
        let books = BookRegistry(repo: repo)
        XCTAssertEqual(books.label(for: padPage).title, "Ncode A4 pad")
        // The registry watches the books directory, not just its own startup.
        Thread.sleep(forTimeInterval: 0.01)
        try write("a4-pad", #"{"id":"s3/o27/b450","title":"Desk pad","first_page":1}"#)
        XCTAssertEqual(books.label(for: padPage).title, "Desk pad")
    }

    func testAStrayJsonFileCannotBreakTheRegistry() throws {
        try write("notes", #"{"something":"else"}"#)
        let books = BookRegistry(repo: repo)
        XCTAssertEqual(books.books.count, 2)
        XCTAssertEqual(books.label(for: padPage).title, "Ncode A4 pad")
    }

    func testDerivedFilePrefersThePngThenTheSvg() throws {
        let dir = repo.appendingPathComponent("pages/a4-pad")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let books = BookRegistry(repo: repo)
        XCTAssertNil(books.derivedFile(for: padPage), "nothing rendered yet")

        try Data().write(to: dir.appendingPathComponent("page-03.svg"))
        XCTAssertEqual(books.derivedFile(for: padPage)?.lastPathComponent, "page-03.svg")
        try Data().write(to: dir.appendingPathComponent("page-03.png"))
        XCTAssertEqual(books.derivedFile(for: padPage)?.lastPathComponent, "page-03.png")
    }

    func testRecentPagesAreNewestFirst() throws {
        let raw = repo.appendingPathComponent("raw/s3/o27/b450")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        for (name, age) in [("p1.jsonl", 300.0), ("p2.jsonl", 10.0), ("p3.jsonl", 100.0)] {
            let url = raw.appendingPathComponent(name)
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        let books = BookRegistry(repo: repo)
        XCTAssertEqual(books.recentPages().map(\.page.page), [2, 3, 1])
        XCTAssertEqual(books.recentPages(limit: 2).count, 2)
    }
}

/// The live view reads back what RawStore wrote, so a round trip has to survive exactly.
final class RawReaderTests: XCTestCase {
    private let page = PageID(section: 3, owner: 27, book: 450, page: 7)

    private func file(_ lines: [String]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("raw-\(UUID().uuidString)/raw/s3/o27/b450")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("p7.jsonl")
        try Data(lines.joined(separator: "\n").appending("\n").utf8).write(to: url)
        return url
    }

    func testStrokesSurviveAWriteReadRoundTrip() throws {
        let original = Stroke(page: page, start: 1_757_530_000_123, end: 1_757_530_000_987,
                              dots: [DotSample(x: 10.5, y: 20.25, force: 0.5, dt: 0),
                                     DotSample(x: 11, y: 21, force: 0.75, dt: 12)],
                              source: .live, penMac: "9c7bd24833d9", firmware: "3.00")
        let url = try file([JSONL.strokeLine(original)])
        let back = RawReader.strokes(at: url)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].dots.map(\.x), [10.5, 11])
        XCTAssertEqual(back[0].dots.map(\.y), [20.25, 21])
        XCTAssertEqual(back[0].start, original.start)
        XCTAssertEqual(back[0].page, page)
    }

    func testMetaLinesAndTornLastLinesAreSkipped() throws {
        // The file is appended to while this reads, so a half-written line is normal, not an error.
        let good = JSONL.strokeLine(Stroke(page: page, start: 1, end: 2,
                                           dots: [DotSample(x: 1, y: 1, force: 0.5, dt: 0)],
                                           source: .live, penMac: "", firmware: ""))
        let url = try file([JSONL.metaLine(captured: 1, client: "t", sdk: "t"), good, "{\"t\":\"str"])
        XCTAssertEqual(RawReader.strokes(at: url).count, 1)
    }

    func testStrokesComeBackInTimeOrder() throws {
        // Arrival order is not chronological: offline strokes land after the first live ones.
        let lines = [3, 1, 2].map { start in
            JSONL.strokeLine(Stroke(page: page, start: start, end: start,
                                    dots: [DotSample(x: 1, y: 1, force: 0.5, dt: 0)],
                                    source: .offline, penMac: "", firmware: ""))
        }
        XCTAssertEqual(RawReader.strokes(at: try file(lines)).map(\.start), [1, 2, 3])
    }

    func testPageGeometryConvertsMillimetresToCells() {
        let a4 = PageGeometry.a4
        XCTAssertEqual(a4.widthCells, 210 / 2.371, accuracy: 0.001)
        XCTAssertEqual(a4.heightCells, 297 / 2.371, accuracy: 0.001)
        XCTAssertLessThan(a4.aspectRatio, 1, "A4 is taller than it is wide")
    }

    func testABookWithNoRecordedSizeStillDraws() {
        let book = BookRecord(slug: "x", id: "s3/o1/b1", title: "X", firstPage: 1)
        XCTAssertEqual(book.geometry, .a4)
        let lamy = BookRecord(slug: "lamy", id: "s3/o1012/b3017", title: "LAMY", firstPage: 1,
                              widthMM: 145, heightMM: 210)
        XCTAssertEqual(lamy.geometry.widthCells, 145 / 2.371, accuracy: 0.001)
    }
}
