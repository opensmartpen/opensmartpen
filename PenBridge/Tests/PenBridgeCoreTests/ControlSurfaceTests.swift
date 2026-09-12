import Foundation
@testable import PenBridgeCore
import XCTest

/// The LAMY paper controller: decoding a tap, and the log of what it selected.
final class ControlSurfaceTests: XCTestCase {
    var root: URL!
    let control = PageID(section: 3, owner: 1013, book: 1, page: 11)
    let note = PageID(section: 3, owner: 27, book: 450, page: 1)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("penbridge-mode-\(UUID().uuidString)")
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
        log.record(.ink(.red), at: 1_000, source: .paper)
        log.record(.width(.thick), at: 2_000, source: .paper)

        let lines = try String(contentsOf: root.appendingPathComponent(ModeLog.relativePath), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"ink\":\"red\""))
        XCTAssertFalse(lines[0].contains("width"), "an ink change must not claim a width")
        XCTAssertTrue(lines[1].contains("\"width\":\"thick\""))
        // Replay still gives the full state.
        XCTAssertEqual(log.state(at: 3_000).ink, .red)
        XCTAssertEqual(log.state(at: 3_000).width, .thick)
    }

    /// The reason the events are deltas. A tap made away from the Mac is delivered by a drain long
    /// after later events are already in the file, so the file is not in time order. Replaying by
    /// time still puts the strokes of that morning in the colour chosen that morning.
    func testATapThatArrivesLateStillAppliesToItsOwnMoment() {
        let log = ModeLog(root: root)
        log.record(.ink(.blue), at: 18_000, source: .panel)   // this evening, at the desk
        log.record(.width(.thick), at: 9_000, source: .paper) // this morning, drained late

        XCTAssertEqual(log.state(at: 9_500).width, .thick, "the morning's strokes were thick")
        XCTAssertEqual(log.state(at: 9_500).ink, .black, "and blue had not been chosen yet")
        XCTAssertEqual(log.state(at: 18_500).ink, .blue)
        XCTAssertEqual(log.state(at: 18_500).width, .thick, "the morning's width survives the evening")
    }

    func testRetappingTheSelectedButtonWritesNothing() {
        let log = ModeLog(root: root)
        XCTAssertTrue(log.record(.ink(.red), at: 1_000, source: .paper))
        XCTAssertFalse(log.record(.ink(.red), at: 2_000, source: .paper))
        XCTAssertEqual(log.events.count, 1)
    }

    /// White is undecided, so it is a dead button: logged as a tap, but it selects nothing.
    func testWhiteSelectsNothing() {
        let log = ModeLog(root: root)
        XCTAssertFalse(log.record(.ink(.white), at: 1_000, source: .paper))
        XCTAssertEqual(log.state(at: 2_000).ink, .black)
    }

    func testStateSurvivesReopeningTheFile() {
        ModeLog(root: root).record(.ink(.green), at: 1_000, source: .paper)
        XCTAssertEqual(ModeLog(root: root).state(at: 2_000).ink, .green)
    }

    // MARK: the coordinator

    func makeCoordinator() throws -> SyncCoordinator {
        let publisher = GitPublisher(repo: root, push: false)
        _ = try publisher.ensureRepository()
        let c = SyncCoordinator(store: RawStore(root: root, client: "c", sdk: "s"),
                                tracker: QuietTracker(), publisher: publisher,
                                notifier: SilentNotifier(), quietWindow: 600)
        c.controlBooks = ["s3/o1013/b1"]
        c.modeLog = ModeLog(root: root)
        return c
    }

    /// A tap is evidence and is kept in raw, but it is not a page: it must never start a countdown
    /// or appear in the pending list as an unclickable notebook.
    func testATapIsStoredButNeverPending() throws {
        let c = try makeCoordinator()
        c.ingestLive([tap(20.02, 43.88)])

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(control.rawRelativePath).path),
                      "the tap itself belongs in raw")
        XCTAssertTrue(c.pendingPages.isEmpty, "but it is not a page waiting to be published")
        XCTAssertEqual(c.modeLog?.state(at: 2_000).ink, .red)
    }

    /// The same exclusion has to hold after a restart. Recovery reads the working tree, where the
    /// tap is uncommitted by design, so without the check it comes straight back into the list.
    func testRecoveryDoesNotResurrectAControlPage() throws {
        let c = try makeCoordinator()
        c.ingestLive([tap(20.02, 43.88)])
        c.ingestLive([stroke(note, start: 5_000)])

        let recovered = try makeCoordinator().recoverPending()
        XCTAssertEqual(recovered, [note], "the note comes back, the tap does not")
    }

}

/// A notifier that says nothing, for tests that are not about notifications.
final class SilentNotifier: Notifier {
    func post(_ notice: Notice) {}
    func reset(_ key: String) {}
}
