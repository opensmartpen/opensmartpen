import Foundation
@testable import BrainioPenCore
import XCTest

/// The reply is the deliverable and is kept whole. The one thing read out of it is the status, and
/// the rule that matters is that a tick is never guessed at.
final class ActionAnswerTests: XCTestCase {
    func testTheStatusLineIsReadAndTakenOff() {
        let answer = ActionAnswer("""
        Ondrej Siroky runs delivery at Apoco. He joined in 2021.

        STATUS: done
        """)
        XCTAssertEqual(answer.status, .done)
        XCTAssertEqual(answer.text, "Ondrej Siroky runs delivery at Apoco. He joined in 2021.")
        XCTAssertEqual(answer.summary, "Ondrej Siroky runs delivery at Apoco. He joined in 2021.")
    }

    func testAQuestionComesBackAsNeedsInfo() {
        let answer = ActionAnswer("Which Tomas? There are two in the address book.\nSTATUS: needs-info")
        XCTAssertEqual(answer.status, .needsInfo)
        XCTAssertEqual(answer.text, "Which Tomas? There are two in the address book.")
    }

    func testBlockedIsRead() {
        XCTAssertEqual(ActionAnswer("No mail account here.\n**STATUS: blocked**").status, .blocked)
    }

    func testARemarkAfterTheStatusWordDoesNotUnmakeIt() {
        // The old prompt listed each status with an explanation after a dash, and a model copied
        // the explanation along. The word is the verdict; the rest is a remark.
        XCTAssertEqual(ActionAnswer("Sent.\nSTATUS: done — you carried it out, and the answer is above.").status, .done)
        XCTAssertEqual(ActionAnswer("Sent.\nSTATUS: done.").status, .done)
        XCTAssertEqual(ActionAnswer("Who?\n`STATUS: needs-info` (which Ondrej)").status, .needsInfo)
        XCTAssertEqual(ActionAnswer("No Slack.\nSTATUS: blocked, no connection here").status, .blocked)
        XCTAssertEqual(ActionAnswer("Sent.\nSTATUS: done — you carried it out.").text, "Sent.")
    }

    func testAWordThatOnlyStartsLikeAStatusIsNotOne() {
        XCTAssertEqual(ActionAnswer("STATUS: donee").status, .unclear)
        XCTAssertEqual(ActionAnswer("STATUS: blockedish").status, .unclear)
    }

    func testAnAnswerWithNoStatusIsNotDone() {
        // The one that would cost something: a tick nobody asked for.
        let answer = ActionAnswer("I have sent it.")
        XCTAssertEqual(answer.status, .unclear)
        XCTAssertEqual(answer.text, "I have sent it.")
    }

    func testAStatusNamedMidSentenceIsNotAVerdict() {
        let answer = ActionAnswer("I checked the status: done column and it was empty.")
        XCTAssertEqual(answer.status, .unclear)
        XCTAssertEqual(answer.text, "I checked the status: done column and it was empty.")
    }

    func testOnlyTheLastStatusCounts() {
        let answer = ActionAnswer("""
        First I tried the old address.
        STATUS: blocked
        Then the new one worked.
        STATUS: done
        """)
        XCTAssertEqual(answer.status, .done)
        XCTAssertTrue(answer.text.contains("STATUS: blocked"))
    }

    func testTheSummaryIsOneLineAndTheTextIsNot() {
        let long = String(repeating: "a", count: 300)
        let answer = ActionAnswer("\(long)\nand a second line\nSTATUS: done")
        XCTAssertEqual(answer.summary?.count, 160)
        XCTAssertTrue(answer.summary!.hasSuffix("…"))
        XCTAssertTrue(answer.text.contains("and a second line"))
    }

    func testAnEmptyReplyIsNotADeliverable() {
        let answer = ActionAnswer("   \n  ")
        XCTAssertEqual(answer.status, .unclear)
        XCTAssertEqual(answer.text, "")
        XCTAssertNil(answer.summary)
    }
}
