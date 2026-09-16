import XCTest
@testable import BrainioPenCore

/// An assistant is offered only once it is switched on and has said what it does, and the
/// transcriber is never one of them.
final class ConfigAssistantsTests: XCTestCase {
    func testOnlyAnsweredAssistantsAreOffered() {
        var config = Config()
        config.damAgentId = "agent-transcriber"
        config.damRoster = [
            DamAgentProfile(id: "agent-transcriber", name: "Transcriber", summary: "I read handwriting."),
            DamAgentProfile(id: "agent-ops", name: "Ops", summary: "Runs the rota.", systems: ["Slack"]),
            DamAgentProfile(id: "agent-new", name: "New"),
        ]
        XCTAssertEqual(config.assistants.map(\.id), ["agent-ops"])
    }

    func testNoTranscriberMeansEveryAnsweredAgentIsAnAssistant() {
        var config = Config()
        config.damRoster = [DamAgentProfile(id: "agent-ops", name: "Ops", summary: "Runs the rota.")]
        XCTAssertEqual(config.assistants.map(\.id), ["agent-ops"])
    }
}
