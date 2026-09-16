import Foundation
@testable import BrainioPenCore
import XCTest

/// An action that has been carried out has changed something outside this Mac. So the only rule
/// worth testing hard is that nothing a later transcript says can make a done action undone.
final class PageActionsTests: XCTestCase {
    func testTheVerdictIsWrittenToTheFileAndReadBack() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("p3.actions.json")
        let action = PageAction(text: "SEND HI TO ONDREJ", thread: [
            ActionMessage(from: .you, text: "go"),
            ActionMessage(from: .agent, text: "No Slack here.", status: .blocked),
        ])
        try PageActions.save([action], to: url)
        let json = try String(contentsOf: url, encoding: .utf8)
        // The word on disk is the word the agent wrote, so the file reads without the app.
        XCTAssertTrue(json.contains("\"status\" : \"blocked\""))
        let back = try XCTUnwrap(PageActions.load(url).first)
        XCTAssertEqual(back.thread[1].status, .blocked)
        XCTAssertNil(back.thread[0].status)
        XCTAssertEqual(back.verdict, .blocked)
    }

    func testAFileFromBeforeTheVerdictStillReads() throws {
        let json = """
        [{"text": "CALL BACK", "done": false, "dismissed": false, "note": null,
          "thread": [{"from": "agent", "text": "Called.", "at": "2026-09-01T10:00:00Z"}]}]
        """
        let actions = try PageActions.decoder.decode([PageAction].self, from: Data(json.utf8))
        XCTAssertNil(actions[0].thread[0].status)
        XCTAssertNil(actions[0].verdict)
    }

    func testTheVerdictIsTheAgentsLastWordNotYours() {
        let action = PageAction(text: "X", thread: [
            ActionMessage(from: .agent, text: "Which one?", status: .needsInfo),
            ActionMessage(from: .you, text: "The second"),
        ])
        XCTAssertEqual(action.verdict, .needsInfo)
    }

    func testTheNewTranscriptDecidesWhichActionsExist() {
        let merged = PageActions.merge(ours: [PageAction(text: "book the room")],
                                       theirs: [PageAction(text: "book the room"),
                                                PageAction(text: "send this to Tomas")])
        XCTAssertEqual(merged.map(\.text), ["book the room", "send this to Tomas"])
    }

    func testADoneActionStaysDoneWhateverTheTranscriptSays() {
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

    func testADoneActionTheTranscriptLostIsKept() {
        // The line was written over, or the transcriber missed it. It still happened.
        let ours = [PageAction(text: "send this to Tomas", done: true)]
        let merged = PageActions.merge(ours: ours, theirs: [PageAction(text: "book the room")])
        XCTAssertEqual(merged.map(\.text), ["book the room", "send this to Tomas"])
        XCTAssertTrue(merged.last!.done)
    }

    func testARewrittenLineKeepsItsWordsAndItsRecordAcrossTheNextTranscript() {
        // A person had the transcriber fix the case and the name. The next transcript of the sheet says
        // what the paper says, in capitals, as it always did.
        let said = [ActionMessage(from: .agent, text: "He runs delivery.")]
        let ours = [PageAction(text: "Find out who is Ondřej Široký", thread: said, session: "s-1",
                               paper: "FIND OUT WHO IS ONDREJ SIROKY")]
        let merged = PageActions.merge(ours: ours, theirs: [PageAction(text: "FIND OUT WHO IS ONDREJ SIROKY")])
        XCTAssertEqual(merged.map(\.text), ["Find out who is Ondřej Široký"])
        XCTAssertEqual(merged[0].paper, "FIND OUT WHO IS ONDREJ SIROKY")
        XCTAssertEqual(merged[0].thread, said)
        XCTAssertEqual(merged[0].session, "s-1")
    }

    func testATranscriberThatKeptTheFixedWordingStillMatches() {
        // Told to keep our entries "exactly as they are", the transcriber may hand the fixed text back,
        // with or without the paper's version beside it. Both are the same line.
        let ours = [PageAction(text: "Find out who is Ondřej Široký", done: true,
                               paper: "FIND OUT WHO IS ONDREJ SIROKY")]
        for theirs in [PageAction(text: "Find out who is Ondřej Široký"),
                       PageAction(text: "Find out who is Ondřej Široký", paper: "FIND OUT WHO IS ONDREJ SIROKY")] {
            let merged = PageActions.merge(ours: ours, theirs: [theirs])
            XCTAssertEqual(merged.count, 1)
            XCTAssertTrue(merged[0].done)
            XCTAssertEqual(merged[0].paper, "FIND OUT WHO IS ONDREJ SIROKY")
        }
    }

    func testAnActionNeverCarriedOutIsDroppedWhenThePageNoLongerSaysIt() {
        let ours = [PageAction(text: "book the room")]
        let merged = PageActions.merge(ours: ours, theirs: [])
        XCTAssertEqual(merged, [])
    }

    func testADismissedActionStaysDismissedWhenThePageStillSaysIt() {
        // You called it off; the paper has not changed its mind and neither has the transcriber.
        let ours = [PageAction(text: "call", dismissed: true)]
        let merged = PageActions.merge(ours: ours, theirs: [PageAction(text: "call")])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].dismissed)
        XCTAssertEqual(merged[0].state, .dismissed)
    }

    func testADismissedActionTheTranscriptLostIsKept() {
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
        // A person can put an action back; a transcript cannot. `update` is the only door either way.
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
