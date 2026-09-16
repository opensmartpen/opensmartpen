import XCTest
@testable import BrainioPenCore

/// A run is one prompt and one answer, with nobody watching. What matters is that the turn is
/// waited for properly, that the agent's own requests are answered the way the platform expects,
/// and that the two ways a run can hang — an approval, a dead socket — end it instead.
final class DamRunTests: XCTestCase {
    private let account = DamAccount(host: "https://dam.example.com/", agentId: "agent-7", apiKey: "pk_test")

    func testTheRelayUrlCarriesTheKeyWhereTheUpgradeReadsIt() throws {
        let runner = try DamRunner(account: account)
        XCTAssertEqual(runner.url.absoluteString,
                       "wss://dam.example.com/api/agents/agent-7/acp?token=pk_test")
    }

    func testAPlainHttpHostIsRefused() {
        XCTAssertThrowsError(try DamRunner(account: DamAccount(host: "http://dam.example.com",
                                                               agentId: "agent-7", apiKey: "pk_test")))
    }

    /// The frame that carries a page. What DAM is given has to be a picture, in front of the
    /// words, or the transcriber is back to opening files and magnifying them.
    func testThePageTravelsWithThePromptAsAPicture() async throws {
        let agent = ScriptedAgent()
        agent.answer("initialize") { _ in ["protocolVersion": 1] }
        agent.answer("session/new") { _ in ["sessionId": "sess-1"] }
        agent.answer("session/prompt") { _ in ["stopReason": "end_turn"] }
        let runner = try DamRunner(account: account, connect: { _ in agent })

        let png = Data([0x89, 0x50, 0x4E, 0x47])
        _ = try await runner.run(prompt: "read it", image: DamImage(data: png, mimeType: "image/png"),
                                 timeout: 10)

        let prompt = try XCTUnwrap(agent.sent.first { $0["method"] as? String == "session/prompt" })
        let blocks = try XCTUnwrap((prompt["params"] as? [String: Any])?["prompt"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["type"] as? String, "image")
        XCTAssertEqual(blocks[0]["mimeType"] as? String, "image/png")
        XCTAssertEqual(blocks[0]["data"] as? String, png.base64EncodedString())
        XCTAssertEqual(blocks[1]["type"] as? String, "text")
        XCTAssertEqual(blocks[1]["text"] as? String, "read it")

        // The session it runs in is the one DAM files headless runs under.
        let created = try XCTUnwrap(agent.sent.first { $0["method"] as? String == "session/new" })
        let platform = ((created["params"] as? [String: Any])?["_meta"] as? [String: Any])?["platform"] as? [String: Any]
        XCTAssertEqual(platform?["type"] as? String, "cli_run")
    }

    func testAPromptWithNoPageIsJustWords() async throws {
        let agent = ScriptedAgent()
        agent.answer("initialize") { _ in [:] }
        agent.answer("session/new") { _ in ["sessionId": "sess-1"] }
        agent.answer("session/prompt") { _ in ["stopReason": "end_turn"] }
        let runner = try DamRunner(account: account, connect: { _ in agent })
        _ = try await runner.run(prompt: "hello", timeout: 10)

        let prompt = try XCTUnwrap(agent.sent.first { $0["method"] as? String == "session/prompt" })
        let blocks = try XCTUnwrap((prompt["params"] as? [String: Any])?["prompt"] as? [[String: Any]])
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["text"])
    }

    func testAPromptRunsToTheEndOfTheTurnAndKeepsWhatWasSaid() async throws {
        let agent = ScriptedAgent()
        agent.answer("initialize") { _ in ["protocolVersion": 1] }
        agent.answer("session/new") { _ in ["sessionId": "sess-1"] }
        agent.answer("session/prompt") { _ in ["stopReason": "end_turn"] }
        // The words arrive before the turn ends, as chunks.
        agent.beforeAnswering("session/prompt") { [
            ["jsonrpc": "2.0", "method": "session/update",
             "params": ["sessionId": "sess-1",
                        "update": ["sessionUpdate": "agent_message_chunk",
                                   "content": ["type": "text", "text": "read "]]]],
            ["jsonrpc": "2.0", "method": "session/update",
             "params": ["sessionId": "sess-1",
                        "update": ["sessionUpdate": "agent_message_chunk",
                                   "content": ["type": "text", "text": "p4"]]]],
        ] }

        let socket = AcpSocket(transport: agent)
        await socket.start()
        _ = try await socket.request("initialize", [:])
        let created = try await socket.request("session/new", [:])
        XCTAssertEqual((created as? [String: Any])?["sessionId"] as? String, "sess-1")
        let answer = try await socket.request("session/prompt", [:])
        XCTAssertEqual((answer as? [String: Any])?["stopReason"] as? String, "end_turn")
        let said = await socket.saidSoFar
        XCTAssertEqual(said, "read p4")
    }

    /// Carrying a conversation on. `session/load` is what `dam run --session` sends, and the
    /// replay it answers with is history: the words of turns that are already filed.
    func testAskingAgainCarriesOnInTheSameSession() async throws {
        let agent = ScriptedAgent()
        agent.answer("initialize") { _ in ["protocolVersion": 1] }
        agent.answer("session/load") { _ in [:] }
        agent.answer("session/prompt") { _ in ["stopReason": "end_turn"] }
        // What a load replays: everything said last time, before the load is answered.
        agent.beforeAnswering("session/load") {
            [["jsonrpc": "2.0", "method": "session/update",
              "params": ["update": ["sessionUpdate": "agent_message_chunk",
                                    "content": ["type": "text", "text": "what I said last time"]]]]]
        }
        agent.beforeAnswering("session/prompt") {
            [["jsonrpc": "2.0", "method": "session/update",
              "params": ["update": ["sessionUpdate": "agent_message_chunk",
                                    "content": ["type": "text", "text": "and now this"]]]]]
        }
        let runner = try DamRunner(account: account, connect: { _ in agent })

        let result = try await runner.run(prompt: "and?", image: nil, resume: "sess-9", timeout: 10)

        XCTAssertEqual(result.sessionId, "sess-9")
        // The old turn is not this turn's answer.
        XCTAssertEqual(result.text, "and now this")
        XCTAssertNil(agent.sent.first { $0["method"] as? String == "session/new" })
        let load = try XCTUnwrap(agent.sent.first { $0["method"] as? String == "session/load" })
        let params = try XCTUnwrap(load["params"] as? [String: Any])
        XCTAssertEqual(params["sessionId"] as? String, "sess-9")
        XCTAssertEqual(params["cwd"] as? String, ".")
        let platform = (params["_meta"] as? [String: Any])?["platform"] as? [String: Any]
        XCTAssertEqual(platform?["tail"] as? Bool, true)
        // And the prompt runs in it.
        let prompt = try XCTUnwrap(agent.sent.first { $0["method"] as? String == "session/prompt" })
        XCTAssertEqual((prompt["params"] as? [String: Any])?["sessionId"] as? String, "sess-9")
    }

    /// A pod that was restarted has never heard of the session. That is not a failure worth
    /// showing anybody: the app carries the exchange in its own file, so the turn starts fresh.
    func testASessionThatIsGoneStartsANewOneRatherThanFailing() async throws {
        let agent = ScriptedAgent()
        agent.answer("initialize") { _ in ["protocolVersion": 1] }
        agent.answer("session/new") { _ in ["sessionId": "sess-2"] }
        agent.answer("session/prompt") { _ in ["stopReason": "end_turn"] }
        agent.fail("session/load", "unknown session")
        let runner = try DamRunner(account: account, connect: { _ in agent })

        let result = try await runner.run(prompt: "and?", image: nil, resume: "sess-gone", timeout: 10)

        XCTAssertEqual(result.sessionId, "sess-2")
        XCTAssertNotNil(agent.sent.first { $0["method"] as? String == "session/new" })
    }

    func testTheAgentsFilesystemRequestsAreAnsweredEmptyNotIgnored() async throws {
        let agent = ScriptedAgent()
        agent.answer("initialize") { _ in [:] }
        agent.ask(["jsonrpc": "2.0", "id": 99, "method": "fs/read_text_file",
                   "params": ["path": "/work/anything"]])
        let socket = AcpSocket(transport: agent)
        await socket.start()
        _ = try await socket.request("initialize", [:])

        let reply = try await agent.waitForReply(to: 99)
        XCTAssertEqual((reply["result"] as? [String: Any])?["content"] as? String, "")
    }

    func testAPermissionRequestEndsTheRunInsteadOfWaitingForNobody() async throws {
        let agent = ScriptedAgent()
        agent.answer("initialize") { _ in [:] }
        // No answer to the prompt: in life the turn would sit there until a person approves.
        agent.ask(["jsonrpc": "2.0", "id": 42, "method": "session/request_permission",
                   "params": ["sessionId": "sess-1", "toolCall": ["title": "Bash(git push)"]]],
                  after: "session/prompt")
        let socket = AcpSocket(transport: agent)
        await socket.start()
        _ = try await socket.request("initialize", [:])
        do {
            _ = try await socket.request("session/prompt", [:])
            XCTFail("a stalled run should not look like a finished one")
        } catch {
            XCTAssertEqual(error as? DamRunError, .stalled("Bash(git push)"))
        }
    }

    /// With somebody watching, the same request is a question rather than the end of the run: it
    /// goes on the desk, the turn stays up, and the answer goes back down the socket in the shape
    /// the harness expects.
    func testWithADeskAPermissionRequestIsAskedRatherThanFatal() async throws {
        let agent = ScriptedAgent()
        agent.answer("initialize") { _ in [:] }
        agent.answer("session/prompt") { _ in ["stopReason": "end_turn"] }
        agent.ask(["jsonrpc": "2.0", "id": 42, "method": "session/request_permission",
                   "params": ["sessionId": "sess-1",
                              "options": [["optionId": "yes", "name": "Allow", "kind": "allow_once"]],
                              "toolCall": ["title": "Bash(git push)"]]],
                  after: "session/prompt")
        let desk = ApprovalDesk()
        let socket = AcpSocket(transport: agent, approvals: desk)
        await socket.start()
        _ = try await socket.request("initialize", [:])

        let answer = try await socket.request("session/prompt", [:])
        XCTAssertEqual((answer as? [String: Any])?["stopReason"] as? String, "end_turn")

        var ask: ApprovalAsk?
        for _ in 0..<500 where ask == nil {
            ask = desk.waiting.first
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let waiting = try XCTUnwrap(ask)
        XCTAssertEqual(waiting.title, "Bash(git push)")

        try await desk.decide(waiting, .allowOnce)

        let reply = try await agent.waitForReply(to: 42)
        let outcome = (reply["result"] as? [String: Any])?["outcome"] as? [String: Any]
        XCTAssertEqual(outcome?["outcome"] as? String, "selected")
        XCTAssertEqual(outcome?["optionId"] as? String, "yes")
    }

    /// Stop, mid-turn: the run ends at once, not when the agent gets round to answering, and the
    /// agent is told to stop as well.
    func testAStoppedRunEndsAtOnceAndTellsTheAgent() async throws {
        let agent = ScriptedAgent()
        agent.answer("initialize") { _ in ["protocolVersion": 1] }
        agent.answer("session/new") { _ in ["sessionId": "sess-1"] }
        // No answer to the prompt: the agent is working, for as long as it likes.
        let runner = try DamRunner(account: account, connect: { _ in agent })

        let run = Task { try await runner.run(prompt: "go", timeout: 600) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        run.cancel()
        let outcome = await run.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "stop took as long as the turn")
        guard case .failure(let error) = outcome, error is CancellationError else {
            return XCTFail("expected a cancelled run, got \(outcome)")
        }
        // Wait a beat for the notification, which is sent from a task of its own.
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancel = agent.sent.first { $0["method"] as? String == "session/cancel" }
        XCTAssertEqual((cancel?["params"] as? [String: Any])?["sessionId"] as? String, "sess-1")
    }

    func testADeadSocketFailsWhatIsWaitingAndWhatComesAfter() async throws {
        let agent = ScriptedAgent()
        agent.hangUpOn("session/prompt")
        agent.answer("initialize") { _ in [:] }
        let socket = AcpSocket(transport: agent)
        await socket.start()
        _ = try await socket.request("initialize", [:])
        do {
            _ = try await socket.request("session/prompt", [:])
            XCTFail("a lost connection is not an answer")
        } catch {
            guard case .connection = (error as? DamRunError) else { return XCTFail("wrong error: \(error)") }
        }
        // A second request does not wait for an answer that can never come.
        do {
            _ = try await socket.request("session/prompt", [:])
            XCTFail("the socket is gone")
        } catch {
            guard case .connection = (error as? DamRunError) else { return XCTFail("wrong error: \(error)") }
        }
    }
}

/// An agent on the other end of the socket, scripted frame by frame.
final class ScriptedAgent: AcpTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var outbound: [[String: Any]] = []
    private var answers: [String: ([String: Any]) -> [String: Any]] = [:]
    private var chunks: [String: () -> [[String: Any]]] = [:]
    private var requests: [(after: String?, frame: [String: Any])] = []
    private var errors: [String: String] = [:]
    private var hangUp: String?
    private var replies: [Int: [String: Any]] = [:]
    private var dead = false
    private var frames: [[String: Any]] = []

    /// Every frame the client sent, in order.
    var sent: [[String: Any]] { lock.withLock { frames } }

    func answer(_ method: String, _ make: @escaping ([String: Any]) -> [String: Any]) {
        lock.withLock { answers[method] = make }
    }

    /// Notifications the agent sends before it answers `method`.
    func beforeAnswering(_ method: String, _ make: @escaping () -> [[String: Any]]) {
        lock.withLock { chunks[method] = make }
    }

    /// A request the agent makes of us, either at once or once `after` has been asked.
    func ask(_ frame: [String: Any], after: String? = nil) {
        lock.withLock { requests.append((after, frame)) }
    }

    /// An answer that is an error, which is what DAM sends for a session it has never heard of.
    func fail(_ method: String, _ message: String) {
        lock.withLock { errors[method] = message }
    }

    func hangUpOn(_ method: String) { lock.withLock { hangUp = method } }

    func start() {
        lock.withLock {
            let now = requests.filter { $0.after == nil }.map(\.frame)
            requests.removeAll { $0.after == nil }
            outbound.append(contentsOf: now)
        }
    }

    func cancel() { lock.withLock { dead = true } }

    func send(_ text: String) async throws {
        guard let frame = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        lock.withLock { frames.append(frame) }
        if let id = frame["id"] as? Int, frame["method"] == nil {
            lock.withLock { replies[id] = frame }
            return
        }
        guard let method = frame["method"] as? String else { return }
        if lock.withLock({ hangUp }) == method {
            lock.withLock { dead = true }
            return
        }
        let params = frame["params"] as? [String: Any] ?? [:]
        lock.withLock {
            if let make = chunks[method] { outbound.append(contentsOf: make()) }
            let due = requests.filter { $0.after == method }
            requests.removeAll { $0.after == method }
            outbound.append(contentsOf: due.map(\.frame))
            if let message = errors[method], let id = frame["id"] as? Int {
                outbound.append(["jsonrpc": "2.0", "id": id,
                                 "error": ["code": -32000, "message": message]])
            } else if let make = answers[method], let id = frame["id"] as? Int {
                outbound.append(["jsonrpc": "2.0", "id": id, "result": make(params)])
            }
        }
    }

    func receive() async throws -> String {
        while true {
            if let frame = lock.withLock({ outbound.isEmpty ? nil : outbound.removeFirst() }) {
                return String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
            }
            if lock.withLock({ dead }) { throw URLError(.networkConnectionLost) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// The frame we sent back for the agent's request `id`.
    func waitForReply(to id: Int, within seconds: Double = 2) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let reply = lock.withLock({ replies[id] }) { return reply }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw URLError(.timedOut)
    }
}
