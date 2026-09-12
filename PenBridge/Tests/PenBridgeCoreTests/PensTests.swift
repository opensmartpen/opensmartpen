import XCTest
@testable import PenBridgeCore

/// A pen record has the same shape of problem as a notebook — a hardware id that must never
/// change and a name that must be free to — so it is solved the same way and in the same place.
final class PensTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pens-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    func testAPenIsNamedRatherThanShownAsAMacAddress() {
        let pens = PenRegistry(repo: repo)
        XCTAssertEqual(pens.name(mac: "9c7bd24833d9"), "Pen", "no record yet, but never the MAC")
        pens.create(mac: "9c:7b:d2:48:33:d9", name: "Everyday")
        XCTAssertEqual(pens.name(mac: "9c7bd24833d9"), "Everyday")
    }

    func testMacsCompareTheSameHoweverTheyArePunctuated() {
        let pens = PenRegistry(repo: repo)
        pens.create(mac: "9C:7B:D2:48:33:D9", name: "Everyday")
        XCTAssertNotNil(pens.record(mac: "9c7bd24833d9"))
        XCTAssertNotNil(pens.record(mac: "9c-7b-d2-48-33-d9"))
    }

    func testRenamingAPenDoesNotMoveItsFile() throws {
        let pens = PenRegistry(repo: repo)
        var pen = try XCTUnwrap(pens.create(mac: "aabbccddeeff", name: "Everyday"))
        let slug = pen.slug
        pen.name = "The red one"
        pens.save(pen)
        // The slug is the filename. A display name that dragged the file with it would be a
        // rename that moves data, which is the thing we deliberately do not do.
        XCTAssertEqual(pens.record(mac: "aabbccddeeff")?.slug, slug)
        XCTAssertEqual(pens.record(mac: "aabbccddeeff")?.name, "The red one")
    }

    func testDefaultsAreBlackAtTheDefaultWidthUntilChanged() throws {
        let pens = PenRegistry(repo: repo)
        pens.create(mac: "aabbccddeeff", name: "Everyday")
        let defaults = pens.defaults(mac: "aabbccddeeff")
        XCTAssertEqual(defaults.ink, .black)
        XCTAssertEqual(defaults.width, .default)

        var pen = try XCTUnwrap(pens.record(mac: "aabbccddeeff"))
        pen.ink = .blue
        pen.mode = .highlight
        pens.save(pen)
        XCTAssertEqual(pens.defaults(mac: "aabbccddeeff").ink, .blue)
        XCTAssertEqual(pens.record(mac: "aabbccddeeff")?.mode, .highlight)
    }

    func testARecordWrittenByHandIsRead() throws {
        // Every other test here creates its record through the registry, so a mismatch between
        // what we write and what we read would pass all of them. This one writes the file the way
        // the pipeline and a person do, and reads it back.
        //
        // The values are deliberately NOT the fallbacks: a record saying black/default is
        // indistinguishable from a lookup that found nothing, so it cannot prove the file was read.
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("pens"),
                                                withIntermediateDirectories: true)
        let json = """
        {
          "ink" : "purple",
          "mac" : "9C:7B:D2:48:33:D9",
          "mode" : "highlight",
          "name" : "The red one",
          "width" : "thick"
        }
        """
        try Data(json.utf8).write(to: repo.appendingPathComponent("pens/red.json"))

        let pens = PenRegistry(repo: repo)
        let record = try XCTUnwrap(pens.record(mac: "9c7bd24833d9"))
        XCTAssertEqual(record.name, "The red one")
        XCTAssertEqual(record.mode, .highlight)
        XCTAssertEqual(pens.defaults(mac: "9c7bd24833d9").ink, .purple)
        XCTAssertEqual(pens.defaults(mac: "9c7bd24833d9").width, .thick)
    }

    func testAnUnknownFieldValueFallsBackRatherThanFailing() throws {
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("pens"),
                                                withIntermediateDirectories: true)
        // A newer PenBridge could write a mode this one has never heard of. Read what is
        // understood, ignore the rest — the same forgiveness the raw reader has.
        try Data(#"{"mac":"aabbccddeeff","name":"Future","mode":"sketch","ink":"chartreuse"}"#.utf8)
            .write(to: repo.appendingPathComponent("pens/future.json"))
        let pens = PenRegistry(repo: repo)
        let record = try XCTUnwrap(pens.record(mac: "aabbccddeeff"))
        XCTAssertEqual(record.name, "Future")
        XCTAssertEqual(record.mode, .writing)
        XCTAssertEqual(record.ink, .black)
    }

    func testAPenWithNoUsableNameStillGetsAFilename() {
        XCTAssertEqual(PenRecord.slug(from: "   ", mac: "aabbccddeeff"), "pen-eeff")
        XCTAssertEqual(PenRecord.slug(from: "The Red One", mac: "x"), "the-red-one")
    }
}

/// The menubar warns about the flattest pen used recently, which with more than one pen is rarely
/// the pen in your hand.
final class PenStateTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pen-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testAFlatPenInADrawerStillWarns() {
        let state = PenState(directory: dir)
        let now = Date()
        state.record(mac: "aaaaaaaaaaaa", battery: 92, charging: false, at: now)
        // Not the connected pen, and not in your hand — but you will reach for it tomorrow.
        state.record(mac: "bbbbbbbbbbbb", battery: 9, charging: false,
                     at: now.addingTimeInterval(-6 * 3600))

        let low = state.lowBatteries(threshold: 15, now: now)
        XCTAssertEqual(low.count, 1)
        XCTAssertEqual(low.first?.mac, "bbbbbbbbbbbb")
    }

    func testAPenNobodyHasTouchedForDaysIsNotUrgent() {
        let state = PenState(directory: dir)
        let now = Date()
        state.record(mac: "cccccccccccc", battery: 4, charging: false,
                     at: now.addingTimeInterval(-5 * 86_400))
        // You would find it flat and charge it. That is different from being surprised mid-sentence.
        XCTAssertTrue(state.lowBatteries(threshold: 15, now: now).isEmpty)
    }

    func testAChargingPenIsNotAProblem() {
        let state = PenState(directory: dir)
        let now = Date()
        state.record(mac: "dddddddddddd", battery: 6, charging: true, at: now)
        XCTAssertTrue(state.lowBatteries(threshold: 15, now: now).isEmpty)
    }

    func testTheFlattestComesFirst() {
        let state = PenState(directory: dir)
        let now = Date()
        state.record(mac: "eeeeeeeeeeee", battery: 14, charging: false, at: now)
        state.record(mac: "ffffffffffff", battery: 3, charging: false, at: now)
        XCTAssertEqual(state.lowBatteries(threshold: 15, now: now).first?.mac, "ffffffffffff")
    }

    func testReadingsSurviveARestart() {
        let now = Date()
        PenState(directory: dir).record(mac: "9C:7B:D2:48:33:D9", battery: 11, charging: false, at: now)
        // A pen that went flat before you quit is still flat when you come back.
        let reopened = PenState(directory: dir)
        XCTAssertEqual(reopened.reading(mac: "9c7bd24833d9")?.battery, 11)
        XCTAssertEqual(reopened.lowBatteries(threshold: 15, now: now).count, 1)
    }
}

/// Two identical pads report the same Ncode book, so a second copy has to be noticed rather than
/// assumed. Detection only ever asks.
final class InstanceTests: XCTestCase {
    private let book = "s3/o27/b450"
    private let day = 86_400_000

    func testOrdinaryWritingRaisesNothing() {
        let watcher = InstanceWatcher()
        XCTAssertNil(watcher.note(book: book, page: 1, at: 0))
        XCTAssertNil(watcher.note(book: book, page: 2, at: day))
        XCTAssertNil(watcher.note(book: book, page: 3, at: 2 * day))
    }

    func testStartingAgainAtTheFrontIsAQuestion() {
        let watcher = InstanceWatcher()
        for page in 1...14 { _ = watcher.note(book: book, page: page, at: page * 1000) }
        let suspicion = watcher.note(book: book, page: 1, at: 3 * day)
        XCTAssertEqual(suspicion?.reason, .sequenceRestart)
    }

    func testReturningToAnEarlyPageOnTheSameDayIsNotAQuestion() {
        let watcher = InstanceWatcher()
        for page in 1...14 { _ = watcher.note(book: book, page: page, at: page * 1000) }
        // Flipping back to annotate page 2 an hour later is ordinary use, not a new pad.
        XCTAssertNil(watcher.note(book: book, page: 2, at: 3_600_000))
    }

    func testALongSilenceAndADistantPageIsAQuestion() {
        let watcher = InstanceWatcher()
        _ = watcher.note(book: book, page: 40, at: 0)
        let suspicion = watcher.note(book: book, page: 80, at: 40 * day)
        XCTAssertEqual(suspicion?.reason, .longGap)
    }

    func testTheSameQuestionIsNotAskedTwice() {
        let watcher = InstanceWatcher()
        for page in 1...14 { _ = watcher.note(book: book, page: page, at: page * 1000) }
        XCTAssertNotNil(watcher.note(book: book, page: 1, at: 3 * day))
        XCTAssertNil(watcher.note(book: book, page: 2, at: 4 * day), "declined once is declined")
    }

    func testABoundaryRoutesLaterPagesToAFreshDirectory() {
        let record = BookRecord(slug: "a4-pad", id: book, title: "A4 pad", firstPage: 1,
                                instances: [BookInstance(slug: "a4-pad", startedAt: 0),
                                            BookInstance(slug: "a4-pad-2", startedAt: 5_000)])
        XCTAssertEqual(record.directory(at: 4_999), "a4-pad")
        XCTAssertEqual(record.directory(at: 5_000), "a4-pad-2")
    }

    func testANotebookWithOneCopyHasNoBoundariesAtAll() {
        let record = BookRecord(slug: "a4-pad", id: book, title: "A4 pad", firstPage: 1)
        XCTAssertEqual(record.directory(at: 0), "a4-pad")
        XCTAssertEqual(record.directory(at: 9_999_999), "a4-pad")
    }
}
