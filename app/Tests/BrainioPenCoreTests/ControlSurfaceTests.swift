import Foundation
@testable import BrainioPenCore
import XCTest

/// The LAMY paper controller: decoding a tap, and the log of what it selected.
final class ControlSurfaceTests: XCTestCase {
    var root: URL!
    let control = PageID(section: 3, owner: 1013, book: 1, page: 11)
    let note = PageID(section: 3, owner: 27, book: 450, page: 1)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brainio-pen-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func tap(_ x: Double, _ y: Double, at start: Int = 1_000) -> Stroke {
        Stroke(page: control, start: start, end: start + 40,
               dots: [DotSample(x: x, y: y, force: 0.5, dt: 0)],
               source: .live, penMac: "M", firmware: "F")
    }

    func stroke(_ page: PageID, start: Int) -> Stroke {
        let x = Double(start % 1000)
        return Stroke(page: page, start: start, end: start + 10,
                      dots: [DotSample(x: x, y: 2, force: 0.5, dt: 0)],
                      source: .live, penMac: "M", firmware: "F")
    }

    // MARK: decoding

    /// The six taps Matous actually made on 2026-09-12, paired with the line he wrote after each.
    func testRealTapsDecodeToTheButtonsTheyWerePressed() {
        let observed: [(Double, Double, ControlButton)] = [
            (9.71, 52.94, .width(.medium)), (20.02, 43.88, .ink(.red)),
            (9.80, 60.13, .width(.thick)),  (19.99, 48.32, .ink(.blue)),
            (9.87, 46.33, .width(.thin)),   (20.18, 53.21, .ink(.green)),
        ]
        for (x, y, expected) in observed {
            XCTAssertEqual(ControlMap.button(atX: x, y: y), expected, "tap at \(x), \(y)")
        }
    }

    /// A tap that lands nowhere near a button is refused, not snapped to the nearest one. Resting
    /// the pen on the strip must not silently log a colour change nobody made.
    func testTapAwayFromEveryButtonIsRefused() {
        XCTAssertNil(ControlMap.button(atX: 30, y: 50))
        XCTAssertNil(ControlMap.button(atX: 14, y: 10))
        XCTAssertNil(ControlMap.button(atX: 9.8, y: 25))
    }

    // MARK: the log

    func testOnlyTheFieldThatChangedIsRecorded() throws {
        let log = ModeLog(root: root)
        log.record(.ink(.red), at: 1_000, client: .pen)
        log.record(.width(.thick), at: 2_000, client: .pen)

        let lines = try String(contentsOf: root.appendingPathComponent(ModeLog.relativePath), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 3, "a header line, then one line per change")
        XCTAssertTrue(lines[1].contains("\"ink\":\"red\""))
        XCTAssertFalse(lines[1].contains("width"), "an ink change must not claim a width")
        XCTAssertTrue(lines[2].contains("\"width\":\"thick\""))
        // Replay still gives the full state.
        XCTAssertEqual(log.state(at: 3_000).ink, .red)
        XCTAssertEqual(log.state(at: 3_000).width, .thick)
    }

    /// The reason the events are deltas. A tap made away from the Mac is delivered by a drain long
    /// after later events are already in the file, so the file is not in time order. Replaying by
    /// time still puts the strokes of that morning in the colour chosen that morning.
    func testATapThatArrivesLateStillAppliesToItsOwnMoment() {
        let log = ModeLog(root: root)
        log.record(.ink(.blue), at: 18_000, client: .app)   // this evening, at the desk
        log.record(.width(.thick), at: 9_000, client: .pen) // this morning, drained late

        XCTAssertEqual(log.state(at: 9_500).width, .thick, "the morning's strokes were thick")
        XCTAssertEqual(log.state(at: 9_500).ink, .black, "and blue had not been chosen yet")
        XCTAssertEqual(log.state(at: 18_500).ink, .blue)
        XCTAssertEqual(log.state(at: 18_500).width, .thick, "the morning's width survives the evening")
    }

    func testRetappingTheSelectedButtonWritesNothing() {
        let log = ModeLog(root: root)
        XCTAssertTrue(log.record(.ink(.red), at: 1_000, client: .pen))
        XCTAssertFalse(log.record(.ink(.red), at: 2_000, client: .pen))
        XCTAssertEqual(log.events.count, 1)
    }

    /// The strip has ten buttons and the repo uses five. A tap on one of the others is a dead
    /// button: stored in raw because the pen saw it, but it selects nothing — an ink with no
    /// colour assigned would otherwise render as a silent black.
    func testAnInkTheRepoDoesNotOfferSelectsNothing() {
        let log = ModeLog(root: root)
        log.offered = [.black, .red, .blue, .green, .yellow]
        XCTAssertFalse(log.record(.ink(.white), at: 1_000, client: .pen))
        XCTAssertFalse(log.record(.ink(.purple), at: 1_500, client: .pen))
        XCTAssertEqual(log.state(at: 2_000).ink, .black)

        XCTAssertTrue(log.record(.ink(.yellow), at: 2_500, client: .pen))
        XCTAssertEqual(log.state(at: 3_000).ink, .yellow)
    }

    /// The field was called `src` while only the strip wrote to the log. A file written then is
    /// still read, because the record is never rewritten to suit a newer reader.
    func testAModeLineWrittenBeforeTheClientFieldIsStillTranscribe() throws {
        let url = root.appendingPathComponent(ModeLog.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {"t":"mode","at":1000,"ink":"red","src":"paper","tap":"0b1c2d3e-4f50-6172-8394-a5b6c7d8e9f0"}
        {"t":"mode","at":2000,"width":"thick","src":"panel"}
        """.write(to: url, atomically: true, encoding: .utf8)

        let log = ModeLog(root: root)
        XCTAssertEqual(log.events.map(\.client), [.pen, .app])
        XCTAssertEqual(log.state(at: 3_000).ink, .red)
        XCTAssertEqual(log.state(at: 3_000).width, .thick)
    }

    func testTheLogStartsWithAHeaderThatNamesTheFormatVersion() throws {
        let log = ModeLog(root: root, app: "brainio-pen-mac/9.9", sdk: "NISDK3/1.1.5")
        log.record(.ink(.red), at: 1_000, client: .pen)
        log.record(.ink(.blue), at: 2_000, client: .app)

        let lines = try String(contentsOf: root.appendingPathComponent(ModeLog.relativePath), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 3, "the header is written once, not before every event")
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(meta["t"] as? String, "meta")
        XCTAssertEqual(meta["v"] as? Int, JSONL.formatVersion)
        XCTAssertEqual(ModeLog(root: root).events.count, 2, "a header is not read back as an event")
    }

    func testTheClientIsRecordedForBothWriters() throws {
        let log = ModeLog(root: root)
        log.record(.ink(.red), at: 1_000, client: .pen, tap: UUID())
        log.record(.width(.thick), at: 2_000, client: .app)

        let lines = try String(contentsOf: root.appendingPathComponent(ModeLog.relativePath), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertTrue(lines[1].contains("\"client\":\"pen\""))
        XCTAssertTrue(lines[2].contains("\"client\":\"app\""))
        XCTAssertFalse(lines.contains { $0.contains("\"src\"") }, "src means one thing only: how a stroke reached us")
    }

    func testStateSurvivesReopeningTheFile() {
        ModeLog(root: root).record(.ink(.green), at: 1_000, client: .pen)
        XCTAssertEqual(ModeLog(root: root).state(at: 2_000).ink, .green)
    }

    // MARK: the palette

    func writePalette() throws {
        try """
        {"ink": {"black": "#000000", "red": "#ff0200", "white": null},
         "width_mm": {"thin": 0.19, "default": 0.29},
         "reset_after_hours": 6}
        """.write(to: root.appendingPathComponent(Palette.relativePath), atomically: true, encoding: .utf8)
    }

    /// A colour with no hex is unmeasured, not black, so it must not arrive as a usable colour.
    func testAnUnmeasuredInkIsAbsentRatherThanBlack() throws {
        try writePalette()
        let p = Palette.load(root: root)
        XCTAssertEqual(p.hex(for: .red), "#ff0200")
        XCTAssertNil(p.hex(for: .white), "null means not measured yet")
        XCTAssertNil(p.hex(for: .navy), "and so does a name the file has never heard of")
        XCTAssertEqual(p.width(for: .thin), 0.19)
        XCTAssertEqual(p.resetAfterHours, 6)
    }

    func testMissingPaletteLeavesEverythingUnknown() {
        let p = Palette.load(root: root)
        XCTAssertNil(p.hex(for: .red))
        XCTAssertEqual(p.resetAfterHours, 24, "but the reset still has a usable default")
    }

    func testComponentsTranscribeTheHex() throws {
        try writePalette()
        let rgb = try XCTUnwrap(Palette.load(root: root).components(for: .red))
        XCTAssertEqual(rgb.r, 1.0, accuracy: 0.01)
        XCTAssertEqual(rgb.g, 0.008, accuracy: 0.01)
        XCTAssertEqual(rgb.b, 0.0, accuracy: 0.01)
    }

    /// The renderer and anything drawing on screen must widen a line the same way, so the curve
    /// lives in the repo. width_mm is the width at typical force, so that is the fixed point.
    func testPressureWidensAroundTheRecordedWidth() throws {
        try writePalette()
        let p = Palette.load(root: root)
        XCTAssertEqual(try XCTUnwrap(p.width(for: .default, force: 0.7)), 0.29, accuracy: 0.001,
                       "typical force draws exactly the recorded width")
        XCTAssertLessThan(try XCTUnwrap(p.width(for: .default, force: 0.2)), 0.29)
        XCTAssertGreaterThan(try XCTUnwrap(p.width(for: .default, force: 1.0)), 0.29)
        // Gentle on purpose: a nib does not double in width when pressed.
        let lightest = try XCTUnwrap(p.width(for: .default, force: 0))
        let heaviest = try XCTUnwrap(p.width(for: .default, force: 1))
        XCTAssertLessThan(heaviest / lightest, 2.1)
        XCTAssertNil(p.width(for: .thick, force: 0.7), "a weight the file does not record has no width")
    }

    /// The pen's LED follows the choice, so a change has to announce itself.
    func testAChangeIsAnnouncedWithTheStateNowInForce() {
        let log = ModeLog(root: root)
        var seen: [(InkColor, LineWidth)] = []
        log.onChange = { seen.append(($0, $1)) }
        log.record(.width(.thick), at: 1_000, client: .pen)
        log.record(.ink(.red), at: 2_000, client: .app)
        log.record(.ink(.red), at: 3_000, client: .app)

        XCTAssertEqual(seen.count, 2, "a re-tap changes nothing, so it announces nothing")
        XCTAssertEqual(seen.last?.0, .red)
        XCTAssertEqual(seen.last?.1, .thick, "the whole state, not just the field that moved")
    }

    // MARK: the coordinator

    func makeCoordinator() throws -> (SyncCoordinator, BookRegistry, RawStore) {
        let publisher = GitPublisher(repo: root, push: false)
        _ = try publisher.ensureRepository()
        let store = RawStore(root: root, app: "c", sdk: "s")
        let books = BookRegistry(root: root)
        let c = SyncCoordinator(store: store, router: PageRouter(books: books, store: store),
                                tracker: QuietTracker(), publisher: publisher,
                                notifier: SilentNotifier(), quietWindow: 600)
        c.controlBooks = ["s3/o1013/b1"]
        c.modeLog = ModeLog(root: root)
        return (c, books, store)
    }

    /// The copy a page is in right now. Folder ids are generated, so a test asks rather than spells.
    func ref(_ page: PageID, _ books: BookRegistry) throws -> PageRef {
        PageRef(folder: try XCTUnwrap(books.current(for: page.surface)).folder, page: page)
    }

    /// A tap is evidence and is kept in raw, but it is not a page: it must never start a countdown
    /// or appear in the pending list as an unclickable notebook.
    func testATapIsStoredButNeverPending() throws {
        let (c, books, store) = try makeCoordinator()
        c.ingestLive([tap(20.02, 43.88)])

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: try ref(control, books)).path),
                      "the tap itself belongs in the record")
        XCTAssertTrue(c.pendingPages.isEmpty, "but it is not a page waiting to be published")
        XCTAssertEqual(c.modeLog?.state(at: 2_000).ink, .red)
    }

    /// The same exclusion has to hold after a restart. Recovery reads the working tree, where the
    /// tap is uncommitted by design, so without the check it comes straight back into the list.
    func testRecoveryDoesNotResurrectAControlPage() throws {
        let (c, books, _) = try makeCoordinator()
        c.ingestLive([tap(20.02, 43.88)])
        c.ingestLive([stroke(note, start: 5_000)])

        let recovered = try makeCoordinator().0.recoverPending()
        XCTAssertEqual(recovered, [try ref(note, books)], "the note comes back, the tap does not")
    }

}

/// A notifier that says nothing, for tests that are not about notifications.
final class SilentNotifier: Notifier {
    func post(_ notice: Notice) {}
    func reset(_ key: String) {}
}
