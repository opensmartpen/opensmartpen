import Foundation
@testable import BrainioPenCore
import XCTest

/// An agent is asked once what it is for, and the answer is what the reader later chooses from.
/// It is a model answering, so the parsing has to survive a model being helpful.
final class AgentProfileAnswerTests: XCTestCase {
    func testTheTwoLinesAreRead() {
        let answer = AgentProfileAnswer("""
        SUMMARY: I run the team's Slack and keep the sprint board honest.
        SYSTEMS: Slack, Jira, GitHub
        """)
        XCTAssertEqual(answer.summary, "I run the team's Slack and keep the sprint board honest.")
        XCTAssertEqual(answer.systems, ["Slack", "Jira", "GitHub"])
    }

    func testDecorationAndPreambleDoNotStopIt() {
        let answer = AgentProfileAnswer("""
        Sure — here you go:

        - **SUMMARY:** I draft and send email.
        - **SYSTEMS:** Gmail, Google Calendar
        """)
        XCTAssertEqual(answer.summary, "I draft and send email.")
        XCTAssertEqual(answer.systems, ["Gmail", "Google Calendar"])
    }

    func testAnAgentWithNoConnectionsSaysSo() {
        let answer = AgentProfileAnswer("SUMMARY: I read handwriting.\nSYSTEMS: none")
        XCTAssertEqual(answer.systems, [])
        XCTAssertEqual(answer.summary, "I read handwriting.")
    }

    func testAnAgentThatIgnoredTheShapeStillGetsALine() {
        // Better a first sentence somebody can read and correct than an empty row.
        let answer = AgentProfileAnswer("I mostly do animation work.\nAnd some video.")
        XCTAssertEqual(answer.summary, "I mostly do animation work.")
        XCTAssertEqual(answer.systems, [])
    }

    func testARamblingSummaryIsCutToSomethingAListCanHold() {
        let answer = AgentProfileAnswer("SUMMARY: " + String(repeating: "x", count: 400))
        XCTAssertEqual(answer.summary?.count, 200)
    }
}

/// One key, several agents. What matters is that a turn goes to the agent it was routed to, and
/// that the reader's own account is what everything else is built from.
final class DamAgentsTests: XCTestCase {
    private let reader = DamAccount(host: "https://dam.example.com", agentId: "agent-reader",
                                    apiKey: "pk_test")

    func testAnAgentGetsItsOwnRelayOnTheSameKey() throws {
        let fleet = try DamAgents(reader: reader)
        let other = try XCTUnwrap(fleet.prompter(for: "agent-slack") as? DamRunner)
        XCTAssertEqual(other.url.absoluteString,
                       "wss://dam.example.com/api/agents/agent-slack/acp?token=pk_test")
        let mine = try XCTUnwrap(fleet.prompter(for: nil) as? DamRunner)
        XCTAssertEqual(mine.url.absoluteString,
                       "wss://dam.example.com/api/agents/agent-reader/acp?token=pk_test")
    }

    func testTheSameAgentIsOnlyBuiltOnce() throws {
        let fleet = try DamAgents(reader: reader)
        XCTAssertTrue(try fleet.prompter(for: "agent-slack") as AnyObject
                      === fleet.prompter(for: "agent-slack") as AnyObject)
    }

    func testAPlainHttpHostIsRefusedBeforeAnythingIsSent() {
        XCTAssertThrowsError(try DamAgents(reader: DamAccount(host: "http://dam.example.com",
                                                              agentId: "a", apiKey: "k")))
    }

    func testARosterLineSaysWhoItIsAndWhatItCanReach() {
        let profile = DamAgentProfile(id: "agent-7", name: "Ops", summary: "Runs the rota.",
                                      systems: ["Slack", "PagerDuty"])
        XCTAssertEqual(profile.roster, "- agent-7 (Ops): Runs the rota. Can reach: Slack, PagerDuty.")
    }
}
