import XCTest
@testable import BrainioPenCore

/// Each copy of a notebook is one folder under `books/`, named by the surface identity the client
/// reported and an id we generated, and `book.json` inside it is the only authority on what that
/// copy is (ADR-002). These tests use the real file shape `pipeline/books.py` reads.
final class BooksTests: XCTestCase {
    private var root: URL!
    private let pad = BookFolder(surface: "s3/o27/b450", id: "7f3a9c")
    private let lamy = BookFolder(surface: "s3/o1012/b3017", id: "2b81e4")
    private var padPage: PageRef { PageRef(folder: pad, page: PageID(section: 3, owner: 27, book: 450, page: 3)) }
    private var lamyPage: PageRef { PageRef(folder: lamy, page: PageID(section: 3, owner: 1012, book: 3017, page: 15)) }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("books-tests-\(UUID().uuidString)")
        try write(pad, #"{"surface":"s3/o27/b450","title":"Ncode A4 pad","width_mm":210.0,"first_page":1}"#)
        try write(lamy, #"{"surface":"s3/o1012/b3017","title":"LAMY notebook","first_page":1}"#)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ folder: BookFolder, _ json: String) throws {
        let url = root.appendingPathComponent(folder.recordPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    // MARK: - The folder name

    func testAFolderNameIsTheSurfaceIdentityThenTheId() {
        XCTAssertEqual(pad.name, "s3-o27-b450-7f3a9c")
        XCTAssertEqual(pad.relativePath, "books/s3-o27-b450-7f3a9c")
        XCTAssertEqual(pad.rawPath(page: 4), "books/s3-o27-b450-7f3a9c/raw/p4.jsonl")
        XCTAssertEqual(pad.pagePath(stem: "p1", ext: "svg"),
                       "books/s3-o27-b450-7f3a9c/pages/p1.svg")
    }

    func testAFolderNameParsesBackToTheSurfaceIdentity() {
        XCTAssertEqual(BookFolder(name: "s3-o27-b450-7f3a9c"), pad)
        // A folder somebody made by hand has no id of ours on the end, so it is not a book.
        XCTAssertNil(BookFolder(name: "s3-o27-b450"))
        XCTAssertNil(BookFolder(name: "my-notes"))
        XCTAssertNil(BookFolder(name: "s3-o27-b450-ZZZZZZ"), "an id is 0-9 and a-f only")
    }

    func testAGeneratedIdIsSixHexCharactersAndAvoidsWhatIsTaken() {
        let id = BookFolder.generateID()
        XCTAssertEqual(id.count, 6)
        XCTAssertTrue(BookFolder.isID(id))
        // Every value but one is taken, so the one free value is the only possible answer.
        var taken = Set<String>()
        for a in "0123456789abcdef" where a != "0" {
            taken.formUnion((0..<16).map { _ in String(repeating: String(a), count: 6) })
        }
        taken.formUnion(["111111"])
        XCTAssertTrue(BookFolder.isID(BookFolder.generateID(taken: taken)))
    }

    func testAPageFilePathRoundTrips() {
        XCTAssertEqual(PageRef(rawRelativePath: padPage.rawRelativePath), padPage)
        XCTAssertNil(PageRef(rawRelativePath: "books/s3-o27-b450-7f3a9c/pages/p1.svg"))
        XCTAssertNil(PageRef(rawRelativePath: "books/s3-o27-b450-7f3a9c/book.json"))
        XCTAssertNil(PageRef(rawRelativePath: "mode.jsonl"))
    }

    // MARK: - Reading records

    func testPagesAreLabelledFromTheRecord() {
        let books = BookRegistry(root: root)
        XCTAssertEqual(books.label(for: padPage), PageLabel(title: "Ncode A4 pad", detail: "page 3"))
        XCTAssertEqual(books.label(for: lamyPage).oneLine, "LAMY notebook · page 15")
    }

    func testFirstPageShiftsNcodeOntoThePrintedNumber() throws {
        // A notebook whose first sheet the pen calls page 4.
        let offset = BookFolder(surface: "s3/o99/b1", id: "aaaaaa")
        try write(offset, #"{"surface":"s3/o99/b1","title":"Offset pad","first_page":4}"#)
        let books = BookRegistry(root: root)
        let page = PageRef(folder: offset, page: PageID(section: 3, owner: 99, book: 1, page: 15))
        XCTAssertEqual(books.label(for: page).detail, "page 12")
        XCTAssertEqual(books.record(for: page)?.pageStem(4), "p4",
                       "a readable file carries the page name the client used")
        XCTAssertEqual(books.record(for: page)?.humanPage(4), 1,
                       "and the number a person counts to is still there to read")
    }

    func testUnknownBookIsNeverNamedAfterItsProductCode() {
        // The book number is a product code. A person does not know what 777 means and should
        // not have to, so it never reaches the interface.
        let books = BookRegistry(root: root)
        let stranger = PageRef(folder: BookFolder(surface: "s3/o1/b777", id: "bbbbbb"),
                               page: PageID(section: 3, owner: 1, book: 777, page: 9))
        XCTAssertEqual(books.label(for: stranger), PageLabel(title: "New notebook", detail: nil))
    }

    func testARecognisedProductNamesAndMeasuresItself() throws {
        // Nothing under books/ for it yet — a notebook meeting Brainio Pen for the first time.
        try FileManager.default.removeItem(at: root.appendingPathComponent(lamy.relativePath))
        let books = BookRegistry(root: root)
        let page = PageID(section: 3, owner: 1012, book: 3017, page: 4)
        let record = try XCTUnwrap(books.ensureRecord(for: page))
        XCTAssertEqual(record.title, "LAMY notebook")
        XCTAssertEqual(record.widthMM, 145, "a product we know on sight needs no measuring")
        XCTAssertEqual(record.startedAt, 0, "the first copy was not decided, it was simply first")
        XCTAssertNil(record.decidedBy)
        XCTAssertEqual(books.label(for: PageRef(folder: record.folder, page: page)),
                       PageLabel(title: "LAMY notebook", detail: "page 4"))
    }

    func testAnUnrecognisedBookIsNamedAfterItsPaperNotItsCode() throws {
        let books = BookRegistry(root: root)
        let stranger = PageID(section: 3, owner: 1, book: 777, page: 9)
        let record = try XCTUnwrap(books.ensureRecord(for: stranger))
        XCTAssertEqual(record.title, "Notebook")
        XCTAssertFalse(record.folder.id.contains("777"))
        XCTAssertEqual(books.label(for: PageRef(folder: record.folder, page: stranger)).title, "Notebook")
    }

    func testAKnownProductKnowsHowItIsBoundEvenInAnOldRecord() {
        // The LAMY record says nothing about binding. It is a bound notebook, so it must still
        // open as a spread rather than as loose sheets.
        let books = BookRegistry(root: root)
        XCTAssertEqual(books.record(for: lamyPage)?.binding, .bound)
        XCTAssertEqual(books.record(for: padPage)?.binding, .pad)
    }

    func testABoundNotebookFallsOpenAtFacingPages() {
        let book = BookRecord(folder: lamy, title: "LAMY", firstPage: 1, binding: .bound)
        // Page 1 is a right-hand page, as it is in every bound book: you open the cover and one
        // sheet faces you.
        XCTAssertEqual(book.spread(containing: 1).left, nil)
        XCTAssertEqual(book.spread(containing: 1).right, 1)
        XCTAssertEqual(book.spread(containing: 4).left, 4)
        XCTAssertEqual(book.spread(containing: 4).right, 5)
        XCTAssertEqual(book.spread(containing: 5).left, 4)
        XCTAssertEqual(book.spread(containing: 5).right, 5)

        XCTAssertEqual(BookRecord(folder: pad, title: "Pad", firstPage: 1)
            .spread(containing: 4).left, nil, "a pad is loose sheets")
    }

    // MARK: - Copies

    func testASecondCopyGetsItsOwnFolderAndBecomesTheOneInUse() throws {
        let books = BookRegistry(root: root)
        let first = try XCTUnwrap(books.current(for: "s3/o27/b450"))
        let second = try XCTUnwrap(books.startNewCopy(of: "s3/o27/b450", at: 1_700_000_000_000,
                                                      because: .inkOverlap))
        XCTAssertNotEqual(first.folder, second.folder)
        XCTAssertEqual(first.folder.surface, second.folder.surface, "same product, different copy")
        XCTAssertEqual(books.current(for: "s3/o27/b450")?.folder, second.folder,
                       "the copy in use is the one that began last")
        XCTAssertEqual(books.copies(of: "s3/o27/b450").count, 2)
        XCTAssertEqual(second.decidedBy, .inkOverlap, "a person can see what the app saw")
        XCTAssertEqual(second.startedAt, 1_700_000_000_000)
    }

    func testAPagesOldCopyIsStillFoundAfterANewOneOpens() throws {
        let books = BookRegistry(root: root)
        _ = books.startNewCopy(of: "s3/o27/b450", at: 1_700_000_000_000, because: .sequenceRestart)
        XCTAssertEqual(books.record(for: padPage)?.folder, pad,
                       "a page names its own copy, so nothing behind the boundary moves")
    }

    func testTwoCopiesDoNotShareAFolder() throws {
        let books = BookRegistry(root: root)
        let a = try XCTUnwrap(books.startNewCopy(of: "s3/o27/b450", at: 1, because: .inkOverlap))
        let b = try XCTUnwrap(books.startNewCopy(of: "s3/o27/b450", at: 2, because: .inkOverlap))
        XCTAssertNotEqual(a.folder.id, b.folder.id)
    }

    func testRenamingANotebookMovesNothing() throws {
        let books = BookRegistry(root: root)
        var record = try XCTUnwrap(books.record(for: padPage))
        let before = record.folder
        record.title = "Desk pad"
        XCTAssertTrue(books.save(record))
        XCTAssertEqual(books.record(for: padPage)?.title, "Desk pad")
        XCTAssertEqual(books.record(for: padPage)?.folder, before, "the folder is named by an id")
    }

    func testRenamingANotebookIsPickedUpWithoutRestarting() throws {
        let books = BookRegistry(root: root)
        XCTAssertEqual(books.label(for: padPage).title, "Ncode A4 pad")
        // The registry watches the record files, not just its own startup.
        Thread.sleep(forTimeInterval: 0.01)
        try write(pad, #"{"surface":"s3/o27/b450","title":"Desk pad","first_page":1}"#)
        XCTAssertEqual(books.label(for: padPage).title, "Desk pad")
    }

    func testAStrayFolderCannotBreakTheRegistry() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("books/scratch"),
                                                withIntermediateDirectories: true)
        let books = BookRegistry(root: root)
        XCTAssertEqual(books.books.count, 2)
        XCTAssertEqual(books.label(for: padPage).title, "Ncode A4 pad")
    }

    // MARK: - Files

    func testDerivedFilePrefersThePngThenTheSvg() throws {
        let dir = root.appendingPathComponent("\(pad.relativePath)/pages")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let books = BookRegistry(root: root)
        XCTAssertNil(books.derivedFile(for: padPage), "nothing rendered yet")

        try Data().write(to: dir.appendingPathComponent("p3.svg"))
        XCTAssertEqual(books.derivedFile(for: padPage)?.lastPathComponent, "p3.svg")
        try Data().write(to: dir.appendingPathComponent("p3.png"))
        XCTAssertEqual(books.derivedFile(for: padPage)?.lastPathComponent, "p3.png")
    }

    func testCapturedAndTranscribeableFilesStayApart() {
        XCTAssertTrue(padPage.rawRelativePath.contains("/raw/"))
        XCTAssertTrue(pad.pagePath(stem: "p3", ext: "svg").contains("/pages/"))
    }

    func testRecentPagesAreNewestFirst() throws {
        let raw = root.appendingPathComponent("\(pad.relativePath)/raw")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        for (name, age) in [("p1.jsonl", 300.0), ("p2.jsonl", 10.0), ("p3.jsonl", 100.0)] {
            let url = raw.appendingPathComponent(name)
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        let books = BookRegistry(root: root)
        XCTAssertEqual(books.recentPages().map(\.page.number), [2, 3, 1])
        XCTAssertEqual(books.recentPages(limit: 2).count, 2)
    }
}

/// The live view reads back what RawStore wrote, so a round trip has to survive exactly.
final class RawReaderTests: XCTestCase {
    private let page = PageID(section: 3, owner: 27, book: 450, page: 7)
    private let folder = BookFolder(surface: "s3/o27/b450", id: "7f3a9c")

    private func file(_ lines: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("raw-\(UUID().uuidString)")
        let url = root.appendingPathComponent(folder.rawPath(page: 7))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").appending("\n").utf8).write(to: url)
        return url
    }

    func testStrokesSurviveAWriteTranscribeRoundTrip() throws {
        let original = Stroke(page: page, start: 1_757_530_000_123, end: 1_757_530_000_987,
                              dots: [DotSample(x: 10.5, y: 20.25, force: 0.5, dt: 0),
                                     DotSample(x: 11, y: 21, force: 0.75, dt: 12)],
                              source: .live, penMac: "9c7bd24833d9", firmware: "3.00")
        let url = try file([JSONL.strokeLine(original)])
        let back = RawReader.strokes(at: url, page: page)
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
        let url = try file([JSONL.metaLine(captured: 1, app: "t", sdk: "t"), good, "{\"t\":\"str"])
        XCTAssertEqual(RawReader.strokes(at: url, page: page).count, 1)
    }

    func testStrokesComeBackInTimeOrder() throws {
        // Arrival order is not chronological: offline strokes land after the first live ones.
        let lines = [3, 1, 2].map { start in
            JSONL.strokeLine(Stroke(page: page, start: start, end: start,
                                    dots: [DotSample(x: 1, y: 1, force: 0.5, dt: 0)],
                                    source: .offline, penMac: "", firmware: ""))
        }
        XCTAssertEqual(RawReader.strokes(at: try file(lines), page: page).map(\.start), [1, 2, 3])
    }

    func testPageGeometryConvertsMillimetresToCells() {
        let a4 = PageGeometry.a4
        XCTAssertEqual(a4.widthCells, 210 / 2.371, accuracy: 0.001)
        XCTAssertEqual(a4.heightCells, 297 / 2.371, accuracy: 0.001)
        XCTAssertLessThan(a4.aspectRatio, 1, "A4 is taller than it is wide")
    }

    func testABookWithNoRecordedSizeStillDraws() {
        let book = BookRecord(folder: BookFolder(surface: "s3/o1/b1", id: "cccccc"),
                              title: "X", firstPage: 1)
        XCTAssertEqual(book.geometry, PageGeometry.a4)
        let lamy = BookRecord(folder: BookFolder(surface: "s3/o1012/b3017", id: "2b81e4"),
                              title: "LAMY", firstPage: 1, widthMM: 145, heightMM: 210)
        XCTAssertEqual(lamy.geometry.widthCells, 145 / 2.371, accuracy: 0.001)
    }
}
