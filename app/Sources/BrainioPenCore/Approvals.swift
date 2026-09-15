import Foundation

/// A JSON-RPC id. The protocol allows a number or a string, and an answer has to carry back the
/// one that came — DAM's own egress holds use a UUID, so an app that only understands numbers
/// silently drops them.
public enum RpcId: Hashable, Sendable {
    case number(Int)
    case text(String)

    public init?(_ any: Any?) {
        switch any {
        case let value as Int: self = .number(value)
        case let value as String: self = .text(value)
        default: return nil
        }
    }

    /// As it goes back on the wire.
    public var json: Any {
        switch self {
        case let .number(value): return value
        case let .text(value): return value
        }
    }

    public var described: String {
        switch self {
        case let .number(value): return String(value)
        case let .text(value): return value
        }
    }
}

/// One of the answers the agent offered. `kind` is the platform's own word for it — `allow_once`,
/// `allow_always`, `reject_once`, `reject_always` — and is what a verdict is matched against,
/// because the ids themselves differ from one harness to the next.
public struct ApprovalOption: Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: String?

    public init(id: String, name: String, kind: String?) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// What a person can say back.
///
/// Three, not the platform's five. "Allow permanently" and "deny forever" write a standing rule
/// for the agent, and a standing rule is a thing to write while looking at a list of them, not
/// while a page is halfway through being dealt with. Only the first of those is offered here.
public enum ApprovalVerdict: String, Equatable, Sendable, CaseIterable {
    case allowOnce
    case allowAlways
    case deny

    /// The procedure in DAM's approvals queue that means this.
    var procedure: String {
        switch self {
        case .allowOnce: return "approvals.approveOnce"
        case .allowAlways: return "approvals.approvePermanent"
        // `dismiss` is deny-this-once. `denyForever` writes a rule, which is not a thing to do in
        // passing: it is the answer that is hardest to take back.
        case .deny: return "approvals.dismiss"
        }
    }
}

/// Something the agent may not do until somebody says it can.
///
/// Two shapes arrive on the same socket and are answered in two different places.
///
/// - A **tool call** is the agent's own question, asked inside our session. We answer it on the
///   socket, and the relay mirrors that answer into DAM's queue so the web inbox agrees with us.
/// - An **egress hold** is the platform's. The agent tried to reach a host it has no rule for, the
///   gate stopped the request, and a copy of the question is injected into every client connected
///   to that agent. It is a notice, not a question we may answer: the gate is waiting on a row in
///   the approvals queue, so the answer goes there. Answering it on the socket would be talking to
///   the wrong end — which is exactly what DAM's own web UI avoids doing.
public struct ApprovalAsk: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The agent wants to reach something outside itself.
        case egress(method: String, host: String, path: String)
        /// The agent wants to run something in its own session.
        case tool(String)
    }

    public let id: String
    public let kind: Kind
    /// The row in DAM's approvals queue. Present for an egress hold, which is answered there.
    public let approvalId: String?
    /// The request on our own socket, which is where a tool call is answered.
    public let rpc: RpcId?
    public let options: [ApprovalOption]
    public let at: Date

    public init(id: String, kind: Kind, approvalId: String? = nil, rpc: RpcId? = nil,
                options: [ApprovalOption] = [], at: Date = Date()) {
        self.id = id
        self.kind = kind
        self.approvalId = approvalId
        self.rpc = rpc
        self.options = options
        self.at = at
    }

    public var isEgress: Bool {
        if case .egress = kind { return true }
        return false
    }

    /// One line, as a person reads it.
    public var title: String {
        switch kind {
        case let .egress(method, host, _): return "\(method) \(host)"
        case let .tool(name): return name
        }
    }

    /// The part that is too long for the line above.
    public var detail: String {
        switch kind {
        case let .egress(_, _, path): return path
        case .tool: return ""
        }
    }

    /// Which of the agent's own options means this verdict.
    ///
    /// The same walk DAM does when it answers on our behalf: the exact kind, then anything of the
    /// right sort, then whatever was offered first — because an option list we do not recognise is
    /// still better answered than left hanging.
    public func optionId(for verdict: ApprovalVerdict) -> String? {
        let wanted: String
        switch verdict {
        case .allowOnce: wanted = "allow_once"
        case .allowAlways: wanted = "allow_always"
        case .deny: wanted = "reject_once"
        }
        if let exact = options.first(where: { $0.kind == wanted }) { return exact.id }
        let allowing = verdict != .deny
        if let near = options.first(where: {
            guard let kind = $0.kind else { return false }
            return allowing ? kind.hasPrefix("allow") : kind.hasPrefix("reject")
        }) { return near.id }
        return options.first?.id
    }

    /// The prefix DAM gives the stand-in session id of an egress hold. It is not a session; it is
    /// how a frame with nowhere else to belong is labelled.
    static let egressPrefix = "_egress:"

    /// Read one out of a `session/request_permission` frame.
    public static func read(params: [String: Any], rpc: RpcId, at: Date = Date()) -> ApprovalAsk {
        let call = params["toolCall"] as? [String: Any] ?? [:]
        let raw = call["rawInput"] as? [String: Any] ?? [:]
        let options = (params["options"] as? [[String: Any]] ?? []).compactMap { option -> ApprovalOption? in
            guard let id = option["optionId"] as? String else { return nil }
            return ApprovalOption(id: id, name: option["name"] as? String ?? id,
                                  kind: option["kind"] as? String)
        }
        let session = params["sessionId"] as? String ?? ""

        if session.hasPrefix(egressPrefix) {
            let approvalId = raw["approvalId"] as? String ?? String(session.dropFirst(egressPrefix.count))
            let host = raw["host"] as? String ?? call["title"] as? String ?? "somewhere"
            return ApprovalAsk(id: approvalId,
                               kind: .egress(method: raw["method"] as? String ?? "GET",
                                             host: host,
                                             path: raw["path"] as? String ?? ""),
                               approvalId: approvalId, rpc: rpc, options: options, at: at)
        }
        return ApprovalAsk(id: "tool:\(rpc.described)",
                           kind: .tool(call["title"] as? String ?? "a tool call"),
                           approvalId: nil, rpc: rpc, options: options, at: at)
    }
}

/// Answering DAM's approvals queue.
///
/// Owner-wide, not per agent: the queue lives on the api-server's own tRPC router, and one key
/// with `agents:operate` reaches every row it is bound to.
public protocol DamApprovals: Sendable {
    func decide(approvalId: String, verdict: ApprovalVerdict) async throws
}

/// Where a request for permission waits while somebody decides.
///
/// One per line being carried out, handed to the run and to the window at the same time. The run
/// puts asks on it and goes on waiting; the window shows them and takes the answer. Without one,
/// nothing has changed: a request for permission ends the turn, which is the right behaviour when
/// nobody is looking — a page being read has no desk, on purpose.
public final class ApprovalDesk: @unchecked Sendable {
    /// How an egress hold is answered: in DAM's queue, by row id.
    public typealias Gate = (String, ApprovalVerdict) async throws -> Void

    private let lock = NSLock()
    private var asks: [ApprovalAsk] = []
    private var answerOnSocket: ((RpcId, String?) async -> Void)?
    private let gate: Gate?
    /// Fired on the main queue whenever the list changes, so a window can show it.
    public var onChange: (() -> Void)?

    public init(gate: Gate? = nil) {
        self.gate = gate
    }

    public var waiting: [ApprovalAsk] { lock.withLock { asks } }
    public var isWaiting: Bool { !waiting.isEmpty }

    /// How the socket answers a tool call. Set by the run, once.
    func answerHere(_ answer: @escaping (RpcId, String?) async -> Void) {
        lock.withLock { answerOnSocket = answer }
    }

    /// A question has arrived. The same one twice is one question: DAM injects an egress hold to
    /// every client of the agent, and a reconnect can bring it round again.
    func post(_ ask: ApprovalAsk) {
        let added: Bool = lock.withLock {
            guard !asks.contains(where: { $0.id == ask.id }) else { return false }
            asks.append(ask)
            return true
        }
        if added { changed() }
    }

    func drop(_ id: String) {
        let removed: Bool = lock.withLock {
            let before = asks.count
            asks.removeAll { $0.id == id }
            return asks.count != before
        }
        if removed { changed() }
    }

    /// The turn is over, one way or another, and nobody is waiting for an answer any more. Asks
    /// left on the desk are not questions now: the socket that carried them is gone.
    public func closeUp() {
        let had = lock.withLock { () -> Bool in
            let had = !asks.isEmpty
            asks.removeAll()
            return had
        }
        if had { changed() }
    }

    public func decide(_ ask: ApprovalAsk, _ verdict: ApprovalVerdict) async throws {
        if ask.isEgress {
            guard let approvalId = ask.approvalId else { throw ApprovalError.gone }
            guard let gate else { throw ApprovalError.noQueue }
            try await gate(approvalId, verdict)
        } else {
            guard let rpc = ask.rpc, let answer = lock.withLock({ answerOnSocket }) else {
                throw ApprovalError.gone
            }
            await answer(rpc, ask.optionId(for: verdict))
        }
        drop(ask.id)
    }

    private func changed() {
        guard let onChange else { return }
        DispatchQueue.main.async(execute: onChange)
    }
}

public enum ApprovalError: Error, LocalizedError, Equatable {
    /// The turn it belonged to has ended.
    case gone
    /// No way to reach DAM's approvals queue — no agent is configured.
    case noQueue
    /// Somebody, or the clock, got there first.
    case answeredAlready

    public var errorDescription: String? {
        switch self {
        case .gone: return "that run has already ended"
        case .noQueue: return "no DAM agent is configured, so there is nowhere to answer"
        case .answeredAlready:
            return "it was already answered, or the hold ran out — DAM waits half an hour"
        }
    }
}
