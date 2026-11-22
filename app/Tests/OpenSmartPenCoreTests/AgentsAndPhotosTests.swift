import XCTest
@testable import OpenSmartPenCore

final class AgentsAndPhotosTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: agents

    func testAgentsAreReadInOrderAndAGapIsPassedOver() throws {
        try write(#"{"name":"Claude Code","alive":"2026-11-14T10:00:00Z","url":"https://example.com/a"}"#, to: "agents/0.json")
        try write(#"{"name":"Codex","alive":"2026-11-14T09:00:00.500Z"}"#, to: "agents/1.json")
        try write(#"{"name":"Lost","alive":"2026-11-14T09:00:00Z"}"#, to: "agents/3.json")

        let agents = Agents.load(root: root)
        XCTAssertEqual(agents.map(\.name), ["Claude Code", "Codex", "Lost"], "a removed agent leaves a gap")

        try Agents.remove(0, root: root, client: nil)
        XCTAssertEqual(Agents.load(root: root).map(\.name), ["Codex", "Lost"])
        XCTAssertEqual(agents[0].url, URL(string: "https://example.com/a"))
        XCTAssertNil(agents[1].url)
    }

    /// The address is opened on a click, and it was written by something else.
    func testOnlyAWebAddressIsKept() {
        let json = #"{"name":"A","alive":"2026-11-14T10:00:00Z","url":"file:///etc/passwd"}"#
        XCTAssertNil(AgentRecord(number: 0, json: Data(json.utf8))?.url)
        XCTAssertNil(AgentRecord(number: 0, json: Data(#"{"name":"A"}"#.utf8)), "no time, no agent")
    }

    func testAnAgentIsBehindOnlyWhenAChangeHasWaitedTwoHours() {
        let alive = Date(timeIntervalSince1970: 1_000_000)
        let agent = AgentRecord(number: 0, name: "A", alive: alive)
        let hour: TimeInterval = 3600

        XCTAssertFalse(agent.isBehind(changed: nil, now: alive.addingTimeInterval(99 * hour)), "nothing ever changed")
        XCTAssertFalse(agent.isBehind(changed: alive.addingTimeInterval(-hour), now: alive.addingTimeInterval(99 * hour)),
                       "it has seen the last change; silence since then costs it nothing")
        let changed = alive.addingTimeInterval(hour)
        XCTAssertFalse(agent.isBehind(changed: changed, now: changed.addingTimeInterval(hour)), "one hour is not long")
        XCTAssertTrue(agent.isBehind(changed: changed, now: changed.addingTimeInterval(3 * hour)))
    }

    func testTheLastChangeIsReadFromTheTimeFile() throws {
        try PagePictures.timeFile(at: Date(timeIntervalSince1970: 1_700_000_000.25))
            .write(to: root.appendingPathComponent(PagePictures.timePath))
        XCTAssertEqual(Agents.lastChange(root: root)?.timeIntervalSince1970 ?? 0, 1_700_000_000.25, accuracy: 0.001)
    }

    func testTheSentenceSaysWhereThePagesAre() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("OpenSmartPen")
        let local = Agents.sentence(folder: folder, bucket: nil)
        XCTAssertTrue(local.contains(Agents.setupURL))
        XCTAssertTrue(local.hasSuffix("The pages are in the folder ~/OpenSmartPen on my Mac."))
        XCTAssertTrue(Agents.sentence(folder: folder, bucket: "https://s3.example/notes")
            .hasSuffix("on my Mac, and in the bucket https://s3.example/notes."))
    }

    // MARK: photos

    func testEachPhotoIsTheNextPageOfOneNotebook() throws {
        let books = BookRegistry(root: root)
        let first = try XCTUnwrap(PhotoPages.add(image: Data("one".utf8), ext: "JPG", books: books, root: root, app: "test"))
        let second = try XCTUnwrap(PhotoPages.add(image: Data("two".utf8), ext: "png", books: books, root: root, app: "test"))

        XCTAssertEqual(first.folder, second.folder, "one notebook for every photo")
        XCTAssertEqual([first.number, second.number], [1, 2])
        XCTAssertEqual(books.record(for: first)?.title, "Photos")

        // The picture as it arrived is the record, beside the file that names it.
        let picture = try XCTUnwrap(PhotoPages.image(of: first, root: root))
        XCTAssertEqual(picture.lastPathComponent, "p1.jpg")
        XCTAssertEqual(try Data(contentsOf: picture), Data("one".utf8))

        // And it is a page like any other: found by its raw path, with no strokes in it.
        XCTAssertEqual(PageRef(rawRelativePath: first.rawRelativePath), first)
        XCTAssertTrue(RawReader.strokes(at: root.appendingPathComponent(first.rawRelativePath), page: first.page).isEmpty)
    }

    /// A photo has two times, and they can be a week apart: when it was taken, and when it was added.
    func testAPhotoKeepsWhenItWasTakenBesideWhenItWasAdded() throws {
        let books = BookRegistry(root: root)
        let taken = Date(timeIntervalSince1970: 1_700_000_000)
        let added = Date(timeIntervalSince1970: 1_700_600_000)
        let page = try XCTUnwrap(PhotoPages.add(image: Data("one".utf8), ext: "jpg", taken: taken,
                                                books: books, root: root, app: "test", now: added))
        let text = try String(contentsOf: root.appendingPathComponent(page.rawRelativePath), encoding: .utf8)
        XCTAssertTrue(text.contains(#"{"t":"image","file":"p1.jpg","added":1700600000000,"taken":1700000000000}"#))

        // The sample page was never taken by a camera, and says nothing.
        let sample = try XCTUnwrap(PhotoPages.add(image: Data("two".utf8), ext: "png",
                                                  books: books, root: root, app: "test", now: added))
        let line = try String(contentsOf: root.appendingPathComponent(sample.rawRelativePath), encoding: .utf8)
        XCTAssertTrue(line.contains(#"{"t":"image","file":"p2.png","added":1700600000000}"#))
    }

    func testAPageOfStrokesIsNotAPhoto() throws {
        let books = BookRegistry(root: root)
        let page = PageID(section: 3, owner: 27, book: 5, page: 1)
        let record = try XCTUnwrap(books.ensureRecord(for: page))
        let ref = PageRef(folder: record.folder, page: page)
        try write(#"{"t":"meta","v":1}"# + "\n", to: ref.rawRelativePath)
        XCTAssertNil(PhotoPages.image(of: ref, root: root))
    }
}
