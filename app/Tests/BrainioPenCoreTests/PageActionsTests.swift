import Foundation
@testable import BrainioPenCore
import XCTest

/// An action that has been carried out has changed something outside this Mac. So the only rule
/// worth testing hard is that nothing a later reading says can make a done action undone.
final class PageActionsTests: XCTestCase {
    func testTheNewReadingDecidesWhichActionsExist() {
        let merged = PageActions.merge(ours: [PageAction(text: "book the room")],
                                       theirs: [PageAction(text: "book the room"),
                                                PageAction(text: "send this to Tomas")])
        XCTAssertEqual(merged.map(\.text), ["book the room", "send this to Tomas"])
    }

    func testADoneActionStaysDoneWhateverTheReadingSays() {
        let ours = [PageAction(text: "send this to Tomas", done: true, note: "sent 09:20")]
        let merged = PageActions.merge(ours: ours, theirs: [PageAction(text: "Send this to Tomas")])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].done)
        XCTAssertEqual(merged[0].note, "sent 09:20")
    }

    func testSpacingAndCaseDoNotMakeANewAction() {
        let ours = [PageAction(text: "send this to Tomas", done: true)]
        let merged = PageActions.merge(ours: ours, theirs: [PageAction(text: "  SEND  this to   tomas ")])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].done)
    }

    func testADoneActionTheReadingLostIsKept() {
        // The line was written over, or the reader missed it. It still happened.
        let ours = [PageAction(text: "send this to Tomas", done: true)]
        let merged = PageActions.merge(ours: ours, theirs: [PageAction(text: "book the room")])
        XCTAssertEqual(merged.map(\.text), ["book the room", "send this to Tomas"])
        XCTAssertTrue(merged.last!.done)
    }

    func testAnActionNeverCarriedOutIsDroppedWhenThePageNoLongerSaysIt() {
        let ours = [PageAction(text: "book the room")]
        let merged = PageActions.merge(ours: ours, theirs: [])
        XCTAssertEqual(merged, [])
    }

    func testADismissedActionStaysDismissedWhenThePageStillSaysIt() {
        // You called it off; the paper has not changed its mind and neither has the reader.
        let ours = [PageAction(text: "call", dismissed: true)]
        let merged = PageActions.merge(ours: ours, theirs: [PageAction(text: "call")])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].dismissed)
        XCTAssertEqual(merged[0].state, .dismissed)
    }

    func testADismissedActionTheReadingLostIsKept() {
        let ours = [PageAction(text: "call", dismissed: true)]
        let merged = PageActions.merge(ours: ours, theirs: [PageAction(text: "book the room")])
        XCTAssertEqual(merged.map(\.text), ["book the room", "call"])
        XCTAssertTrue(merged.last!.dismissed)
    }

    func testDismissedOutranksDone() {
        XCTAssertEqual(PageAction(text: "call", done: true, dismissed: true).state, .dismissed)
    }

    func testAFileWrittenWithoutTheDismissedFieldStillReads() throws {
        // What the agent wrote before the field existed, and what it writes if it forgets.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acts-\(UUID().uuidString)/p1.actions.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try #"[{"text": "call", "done": true, "note": null}]"#.write(to: url, atomically: true,
                                                                     encoding: .utf8)
        XCTAssertEqual(PageActions.load(url), [PageAction(text: "call", done: true)])
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testUndoingIsAClickAndNotAMerge() throws {
        // A person can put an action back; a reading cannot. `update` is the only door either way.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acts-\(UUID().uuidString)/p1.actions.json")
        try PageActions.save([PageAction(text: "call", done: true),
                              PageAction(text: "book the room")], to: url)
        try PageActions.update(url, key: PageAction(text: "CALL").key) { $0.done = false }
        XCTAssertEqual(PageActions.load(url).map(\.done), [false, false])

        // And an action the file does not hold changes nothing at all.
        try PageActions.update(url, key: "no such line") { $0.dismissed = true }
        XCTAssertEqual(PageActions.load(url).map(\.dismissed), [false, false])
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testTheFileSurvivesARoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acts-\(UUID().uuidString)/p1.actions.json")
        let actions = [PageAction(text: "send this to Tomas", done: true, note: "sent"),
                       PageAction(text: "book the room")]
        try PageActions.save(actions, to: url)
        XCTAssertEqual(PageActions.load(url), actions)
        XCTAssertEqual(PageActions.load(url.deletingLastPathComponent().appendingPathComponent("none.json")), [])
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
