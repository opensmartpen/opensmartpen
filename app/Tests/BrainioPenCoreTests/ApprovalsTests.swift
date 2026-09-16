import XCTest
@testable import BrainioPenCore

/// DAM stops an agent twice over: at its own gate, when it reaches for a host it has no rule for,
/// and inside the session, when it asks before running something. Both arrive on the same socket
/// and are answered in two different places, and getting that wrong means an agent left hanging
/// for half an hour.
final class ApprovalsTests: XCTestCase {
    /// The frame DAM injects when the egress gate holds a request. Its session id is not a
    /// session: it is a label for a question that belongs to no conversation.
    private let egressFrame: [String: Any] = [
        "sessionId": "_egress:2f9b-1",
        "options": [
            ["optionId": "allow_once", "name": "Allow once", "kind": "allow_once"],
            ["optionId": "allow_always", "name": "Allow permanently", "kind": "allow_always"],
            ["optionId": "reject_always", "name": "Deny forever", "kind": "reject_always"],
        ],
        "toolCall": [
            "toolCallId": "_egress:2f9b-1",
            "title": "POST slack.com/api/chat.postMessage",
            "rawInput": ["approvalId": "2f9b-1", "host": "slack.com", "method": "POST",
                         "path": "/api/chat.postMessage"],
        ],
    ]

    func testAnEgressHoldIsTranscribeAsWhatTheAgentIsTryingToReach() {
        let ask = ApprovalAsk.read(params: egressFrame, rpc: .text("2f9b-1"))

        XCTAssertTrue(ask.isEgress)
        XCTAssertEqual(ask.approvalId, "2f9b-1")
        XCTAssertEqual(ask.title, "POST slack.com")
        XCTAssertEqual(ask.detail, "/api/chat.postMessage")
    }

    /// A tool call is the agent's own question, in our session, and it is answered on the socket —
    /// so what matters is that it is not mistaken for something the approvals queue owns.
    func testAToolCallIsAskedAndAnsweredInTheSession() {
        let ask = ApprovalAsk.read(params: [
            "sessionId": "sess-1",
            "options": [["optionId": "yes", "name": "Allow", "kind": "allow_once"]],
            "toolCall": ["title": "Bash(git push)"],
        ], rpc: .number(42))

        XCTAssertFalse(ask.isEgress)
        XCTAssertNil(ask.approvalId)
        XCTAssertEqual(ask.rpc, .number(42))
        XCTAssertEqual(ask.title, "Bash(git push)")
    }

    func testAVerdictPicksTheAgentsOwnWordForIt() {
        let ask = ApprovalAsk.read(params: egressFrame, rpc: .text("2f9b-1"))
        XCTAssertEqual(ask.optionId(for: .allowOnce), "allow_once")
        XCTAssertEqual(ask.optionId(for: .allowAlways), "allow_always")
        // No `reject_once` on offer: the nearest refusal is taken rather than nothing at all.
        XCTAssertEqual(ask.optionId(for: .deny), "reject_always")
    }

    func testAnUnfamiliarOptionListIsStillAnswered() {
        let ask = ApprovalAsk.read(params: [
            "sessionId": "sess-1",
            "options": [["optionId": "the-only-one", "name": "OK"]],
            "toolCall": ["title": "something"],
        ], rpc: .number(1))
        XCTAssertEqual(ask.optionId(for: .allowOnce), "the-only-one")
    }

    /// The routing that matters: an egress hold must not be answered down the socket, because the
    /// thing waiting for that answer is DAM's gate, not the agent.
    func testAnEgressHoldIsAnsweredInTheQueueAndNotOnTheSocket() async throws {
        let queue = RecordingQueue()
        let desk = ApprovalDesk(gate: { id, verdict in await queue.record(id, verdict) })
        let socket = RecordingSocket()
        desk.answerHere { rpc, optionId in await socket.record(rpc, optionId) }
        let ask = ApprovalAsk.read(params: egressFrame, rpc: .text("2f9b-1"))
        desk.post(ask)

        try await desk.decide(ask, .allowAlways)

        let answered = await queue.answers
        XCTAssertEqual(answered.map(\.0), ["2f9b-1"])
        XCTAssertEqual(answered.map(\.1), [.allowAlways])
        let onSocket = await socket.answers
        XCTAssertTrue(onSocket.isEmpty)
        // Answered means gone: the row has nothing left to ask.
        XCTAssertFalse(desk.isWaiting)
    }

    func testAToolCallIsAnsweredOnTheSocketAndNotInTheQueue() async throws {
        let queue = RecordingQueue()
        let desk = ApprovalDesk(gate: { id, verdict in await queue.record(id, verdict) })
        let socket = RecordingSocket()
        desk.answerHere { rpc, optionId in await socket.record(rpc, optionId) }
        let ask = ApprovalAsk.read(params: [
            "sessionId": "sess-1",
            "options": [["optionId": "yes", "name": "Allow", "kind": "allow_once"]],
            "toolCall": ["title": "Bash(git push)"],
        ], rpc: .number(7))
        desk.post(ask)

        try await desk.decide(ask, .allowOnce)

        let onSocket = await socket.answers
        XCTAssertEqual(onSocket.map(\.0), [RpcId.number(7)])
        XCTAssertEqual(onSocket.map(\.1), ["yes"])
        let answered = await queue.answers
        XCTAssertTrue(answered.isEmpty)
    }

    /// DAM injects an egress hold to every client connected to the agent, and a reconnect brings
    /// it round again. One question is one row.
    func testTheSameQuestionTwiceIsOneQuestion() {
        let desk = ApprovalDesk()
        let ask = ApprovalAsk.read(params: egressFrame, rpc: .text("2f9b-1"))
        desk.post(ask)
        desk.post(ask)
        XCTAssertEqual(desk.waiting.count, 1)
    }

    func testWhenTheTurnEndsThereIsNothingLeftToAnswer() async {
        let desk = ApprovalDesk()
        desk.post(ApprovalAsk.read(params: egressFrame, rpc: .text("2f9b-1")))
        XCTAssertTrue(desk.isWaiting)
        desk.closeUp()
        XCTAssertFalse(desk.isWaiting)
    }

    func testWithNothingBehindItADecisionSaysSoRatherThanLookingLikeAYes() async {
        let desk = ApprovalDesk()
        let ask = ApprovalAsk.read(params: egressFrame, rpc: .text("2f9b-1"))
        desk.post(ask)
        do {
            try await desk.decide(ask, .allowOnce)
            XCTFail("there is no queue to answer in")
        } catch {
            XCTAssertEqual(error as? ApprovalError, .noQueue)
        }
    }
}

private actor RecordingQueue {
    private(set) var answers: [(String, ApprovalVerdict)] = []
    func record(_ id: String, _ verdict: ApprovalVerdict) { answers.append((id, verdict)) }
}

private actor RecordingSocket {
    private(set) var answers: [(RpcId, String?)] = []
    func record(_ rpc: RpcId, _ optionId: String?) { answers.append((rpc, optionId)) }
}
