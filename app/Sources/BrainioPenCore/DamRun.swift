import Foundation

/// What one turn of the agent produced.
public struct DamRunResult: Equatable, Sendable {
    /// The session the turn ran in. Kept so a later run can be read back or continued.
    public let sessionId: String
    /// Everything the agent said, in order. The files it wrote are the real output; this is the
    /// explanation, and it is what a log or a notice quotes when something went wrong.
    public let text: String
    /// Why the turn stopped, as the harness reports it (`end_turn`, `cancelled`, …).
    public let stopReason: String?
}

public enum DamRunError: Error, LocalizedError, Equatable {
    case connection(String)
    case refused(String)
    /// The agent asked for a permission. Nobody is watching, and the request is now sitting in
    /// DAM's approvals queue, so the turn will not finish on its own.
    case stalled(String)
    case timedOut(seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case let .connection(detail): return "the agent could not be reached: \(detail)"
        case let .refused(detail): return "the agent refused the prompt: \(detail)"
        case let .stalled(what): return "the run is waiting for approval in DAM (\(what))"
        case let .timedOut(seconds): return "the agent did not finish within \(Int(seconds))s"
        }
    }
}

/// A picture sent with a prompt, so the model sees it rather than opening it.
public struct DamImage: Equatable, Sendable {
    public let data: Data
    public let mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// One prompt, waited on until the turn ends. A protocol so a test can answer it.
public protocol DamPrompting: Sendable {
    /// `resume` continues an earlier session, so the agent still has what it worked out last time.
    func run(prompt: String, image: DamImage?, resume: String?,
             timeout: TimeInterval) async throws -> DamRunResult
}

public extension DamPrompting {
    func run(prompt: String, image: DamImage? = nil,
             timeout: TimeInterval = 900) async throws -> DamRunResult {
        try await run(prompt: prompt, image: image, resume: nil, timeout: timeout)
    }
}

/// Sends one prompt to a DAM agent and waits for the turn to end — what `dam run` does, over the
/// same relay, in as little code as the job needs.
///
/// The relay is a websocket carrying JSON-RPC both ways: `initialize`, then `session/new`, then
/// `session/prompt`, whose response arrives only when the turn is over. Connecting wakes a
/// hibernated agent, so nothing else has to be done to get one running.
///
/// Three deliberate limits, because this runs with nobody watching:
///
/// - A dropped socket ends the run here. The turn keeps going on the agent and the page is read
///   again on the next tick; reconnecting to watch it would be a second way to reach the same file.
/// - A permission request is not answered. It goes to DAM's approvals queue, where a person deals
///   with it, and the run is reported as stalled rather than waited on for an hour.
/// - Nothing is read from the agent's filesystem on its behalf: `fs/*` requests are answered empty,
///   exactly as the CLI answers them. The agent has its own workspace; that is where the page is.
public final class DamRunner: DamPrompting {
    private let account: DamAccount
    private let session: URLSession
    /// How a socket is made. Replaced in tests by an agent that answers from a script — the shape
    /// of the frames sent is the contract with DAM, and it is worth asserting.
    private let connect: @Sendable (URL) -> AcpTransport

    public convenience init(account: DamAccount, session: URLSession = .shared) throws {
        try self.init(account: account, session: session, connect: nil)
    }

    init(account: DamAccount, session: URLSession = .shared,
         connect: (@Sendable (URL) -> AcpTransport)?) throws {
        guard DamClient.isSecure(account.host) else { throw DamError.insecureHost(account.host) }
        self.account = account
        self.session = session
        self.connect = connect ?? { url in WebSocketTransport(task: session.webSocketTask(with: url)) }
    }

    /// Where the relay lives. The key travels as a query parameter because that is the only slot a
    /// websocket upgrade offers, and it is what the relay reads (`?token=`).
    var url: URL {
        let base = account.host.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let ws = base.replacingOccurrences(of: "^http", with: "ws", options: .regularExpression)
        let agent = account.agentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? account.agentId
        let token = account.apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? account.apiKey
        return URL(string: "\(ws)/api/agents/\(agent)/acp?token=\(token)")!
    }

    /// Run one prompt to completion, with a picture attached when there is one.
    public func run(prompt: String, image: DamImage? = nil, resume: String? = nil,
                    timeout: TimeInterval = 900) async throws -> DamRunResult {
        let socket = AcpSocket(transport: connect(url))
        await socket.start()
        defer { Task { await socket.close() } }

        return try await withDeadline(timeout) {
            _ = try await socket.request("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": [:],
                "clientInfo": ["name": "brainio-pen", "version": "1.0.0"],
            ])

            let sessionId = try await self.session(on: socket, resume: resume)
            // The load replays the old turns as notifications before it answers, and they land in
            // the same place this turn's words will. What we want back is what the agent says now.
            await socket.forgetWhatWasSaid()

            let promptId = UUID().uuidString
            // The picture first, the instructions after it. An attached image is content the model
            // already has; a path is an errand, and an agent given an errand will run tools —
            // opening the file, and then cropping and magnifying it to read it better, which is
            // minutes of work for a picture it could simply have been shown.
            var blocks: [[String: Any]] = []
            if let image {
                blocks.append(["type": "image", "data": image.data.base64EncodedString(),
                               "mimeType": image.mimeType])
            }
            blocks.append(["type": "text", "text": prompt])
            let answer = try await socket.request("session/prompt", [
                "sessionId": sessionId,
                "prompt": blocks,
                "_meta": ["platform": ["promptId": promptId, "surface": "brainio-pen"]],
            ])
            let stopReason = (answer as? [String: Any])?["stopReason"] as? String
            return DamRunResult(sessionId: sessionId, text: await socket.saidSoFar, stopReason: stopReason)
        }
    }

    /// The session this turn runs in: the one asked for, or a new one.
    ///
    /// `session/load` is how `dam run --session` carries a conversation on, and it is why a second
    /// question to the agent is not a stranger asking again — the agent still has what it looked
    /// up the first time. A session that cannot be loaded is not an error worth showing anybody:
    /// the pod may have been restarted, and the app carries the exchange in its own file anyway,
    /// so it starts a fresh one and says so in the log.
    private func session(on socket: AcpSocket, resume: String?) async throws -> String {
        if let resume {
            do {
                _ = try await socket.request("session/load", [
                    "sessionId": resume,
                    "cwd": ".",
                    "mcpServers": [],
                    "_meta": ["platform": ["tail": true]],
                ])
                return resume
            } catch {
                Log.info("the agent could not carry on session \(resume) (\(error)); starting a new one")
            }
        }
        // `cli_run` is the session type DAM files headless runs under, so these turns are told
        // apart from a person's chat in the agent's own session list.
        let created = try await socket.request("session/new", [
            "cwd": ".",
            "mcpServers": [],
            "_meta": ["platform": ["mode": "chat", "type": "cli_run"]],
        ])
        guard let sessionId = (created as? [String: Any])?["sessionId"] as? String else {
            throw DamRunError.refused("the agent returned no session id")
        }
        return sessionId
    }

    /// Races the work against the clock. A turn that outlives the deadline is left running on the
    /// agent: its output is a file, and the file is picked up whenever it appears.
    private func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                                           _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DamRunError.timedOut(seconds: seconds)
            }
            guard let first = try await group.next() else { throw DamRunError.connection("nothing happened") }
            group.cancelAll()
            return first
        }
    }
}

/// The socket underneath, as little of it as the protocol needs — so the frame handling above can
/// be tested against a scripted agent rather than a live one.
protocol AcpTransport: Sendable {
    func start()
    func send(_ text: String) async throws
    /// One frame. Throws when the socket is gone, which is how the read loop ends.
    func receive() async throws -> String
    func cancel()
}

/// The real thing: a websocket to the agent's ACP relay.
struct WebSocketTransport: AcpTransport {
    let task: URLSessionWebSocketTask

    func start() { task.resume() }
    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }

    func receive() async throws -> String {
        switch try await task.receive() {
        case let .string(text): return text
        case let .data(data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }
}

/// One websocket speaking JSON-RPC: requests out with an id to match the answer, notifications in,
/// and the agent's own requests answered the way the platform expects.
actor AcpSocket {
    private let transport: AcpTransport
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var said = ""
    private var closed = false
    /// Why the socket ended. Kept so a request made after the end fails at once rather than waiting
    /// for an answer that can no longer arrive.
    private var ended: Error?

    init(transport: AcpTransport) {
        self.transport = transport
    }

    /// Everything the agent has said so far.
    var saidSoFar: String { said }

    /// Throw away what has been collected. Used after a session is loaded, when what arrived was
    /// the replay of turns that are already filed.
    func forgetWhatWasSaid() { said = "" }

    func start() {
        transport.start()
        Task { await listen() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        transport.cancel()
        fail(DamRunError.connection("closed"))
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> Any? {
        if let ended { throw ended }
        let id = nextId
        nextId += 1
        try await send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
        }
    }

    private func send(_ frame: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: frame, options: [.withoutEscapingSlashes])
        do {
            try await transport.send(String(decoding: data, as: UTF8.self))
        } catch {
            throw DamRunError.connection(error.localizedDescription)
        }
    }

    private func listen() async {
        while !closed {
            do {
                let text = try await transport.receive()
                guard let frame = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                else { continue }
                await handle(frame)
            } catch {
                fail(DamRunError.connection(error.localizedDescription))
                return
            }
        }
    }

    private func handle(_ frame: [String: Any]) async {
        let id = frame["id"] as? Int
        let method = frame["method"] as? String

        // An answer to something we asked.
        if let id, method == nil {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = frame["error"] as? [String: Any] {
                continuation.resume(throwing: DamRunError.refused(error["message"] as? String ?? "\(error)"))
            } else {
                continuation.resume(returning: frame["result"])
            }
            return
        }

        // A request from the agent.
        if let id, let method {
            if method == "session/request_permission" {
                let title = ((frame["params"] as? [String: Any])?["toolCall"] as? [String: Any])?["title"] as? String
                fail(DamRunError.stalled(title ?? "a tool call"))
                return
            }
            let answers: [String: Any] = ["fs/read_text_file": ["content": ""], "fs/write_text_file": [:]]
            if let answer = answers[method] {
                try? await send(["jsonrpc": "2.0", "id": id, "result": answer])
            } else {
                try? await send(["jsonrpc": "2.0", "id": id,
                                 "error": ["code": -32601, "message": "unsupported: \(method)"]])
            }
            return
        }

        // A notification. Only the agent's own words are kept.
        if method == "session/update",
           let update = (frame["params"] as? [String: Any])?["update"] as? [String: Any],
           update["sessionUpdate"] as? String == "agent_message_chunk",
           let content = update["content"] as? [String: Any],
           content["type"] as? String == "text",
           let text = content["text"] as? String {
            said += text
        }
    }

    /// Everything still waiting fails together: the socket is the only way an answer can arrive.
    private func fail(_ error: Error) {
        if ended == nil { ended = error }
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}
