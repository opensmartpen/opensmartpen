import Foundation

/// One agent this app may hand work to, and what it says about itself.
///
/// The summary and the list of systems are not written by us. They are asked of the agent once,
/// when it is added, because an agent knows what it is for and we would only be guessing — and
/// because the reader is given this list to choose from, and a list written by hand goes stale the
/// day somebody connects a new tool.
public struct DamAgentProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// One sentence: what this agent is for.
    public var summary: String?
    /// What it can reach — Slack, a calendar, a repository. Empty means it said none.
    public var systems: [String]
    /// When it was last asked. Nil means never, and the settings window offers to ask.
    public var askedAt: Date?

    public init(id: String, name: String, summary: String? = nil, systems: [String] = [],
                askedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.systems = systems
        self.askedAt = askedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        systems = try c.decodeIfPresent([String].self, forKey: .systems) ?? []
        askedAt = try c.decodeIfPresent(Date.self, forKey: .askedAt)
    }

    /// One line for a prompt: who it is, what it does, what it can reach.
    public var roster: String {
        var line = "- \(id) (\(name)): \(summary ?? "no description")"
        if !systems.isEmpty { line += " Can reach: \(systems.joined(separator: ", "))." }
        return line
    }
}

/// Every agent the key can reach, as things that can be prompted and written to.
///
/// One key, several agents, and a deliberate split: the agent that **reads** pages is chosen to be
/// one with no confidential connections, because it is the one looking at whatever is written on a
/// page — and a page is an untrusted document. The agents that **carry actions out** are the ones
/// with the keys to Slack, mail and the rest. A page cannot talk to them; it can only ask the
/// reader to propose one, and a person can always change the answer.
public protocol DamFleet: Sendable {
    /// Nil means the reader.
    func prompter(for agentId: String?) throws -> DamPrompting
    func workspace(for agentId: String?) throws -> DamWorkspace
}

public final class DamAgents: DamFleet, @unchecked Sendable {
    /// The account of the agent that reads pages.
    private let reader: DamAccount
    private let session: URLSession
    private let lock = NSLock()
    private var prompters: [String: DamPrompting] = [:]
    private var workspaces: [String: DamWorkspace] = [:]

    /// Refuses a plain-http host here rather than at the first turn: a setup that cannot work
    /// should say so while somebody is still looking at the settings window.
    public init(reader: DamAccount, session: URLSession = .shared) throws {
        guard DamClient.isSecure(reader.host) else { throw DamError.insecureHost(reader.host) }
        self.reader = reader
        self.session = session
    }

    private func account(_ agentId: String?) -> DamAccount {
        guard let agentId, !agentId.isEmpty, agentId != reader.agentId else { return reader }
        return DamAccount(host: reader.host, agentId: agentId, apiKey: reader.apiKey)
    }

    public func prompter(for agentId: String?) throws -> DamPrompting {
        let account = account(agentId)
        if let made = lock.withLock({ prompters[account.agentId] }) { return made }
        let made = try DamRunner(account: account, session: session)
        lock.withLock { prompters[account.agentId] = made }
        return made
    }

    public func workspace(for agentId: String?) throws -> DamWorkspace {
        let account = account(agentId)
        if let made = lock.withLock({ workspaces[account.agentId] }) { return made }
        let made = try DamClient(account: account, session: session)
        lock.withLock { workspaces[account.agentId] = made }
        return made
    }
}

/// One agent doing everything, which is what the app was before there was a fleet. Kept for a
/// setup with a single agent, and for tests.
public struct OneAgent: DamFleet {
    private let prompting: DamPrompting
    private let space: DamWorkspace

    public init(prompter: DamPrompting, workspace: DamWorkspace) {
        prompting = prompter
        space = workspace
    }

    public func prompter(for agentId: String?) throws -> DamPrompting { prompting }
    public func workspace(for agentId: String?) throws -> DamWorkspace { space }
}

/// What an agent says when it is asked what it is for.
///
/// Two lines, asked for in that shape because a paragraph would have to be read by something, and
/// the thing that reads it would be another model. The answer is stored and shown to a person, who
/// can see at a glance whether the agent understood the question.
public struct AgentProfileAnswer: Equatable {
    public let summary: String?
    public let systems: [String]

    public init(_ reply: String) {
        var summary: String?
        var systems: [String] = []
        for line in reply.components(separatedBy: .newlines) {
            let clean = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t*_-#>`"))
            if let value = Self.value(of: "summary", in: clean), summary == nil, !value.isEmpty {
                summary = value
            }
            if let value = Self.value(of: "systems", in: clean), systems.isEmpty {
                systems = value.split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t*_`.")) }
                    .filter { !$0.isEmpty && $0.lowercased() != "none" }
            }
        }
        // An agent that ignored the shape still said something. Its first line is better than
        // nothing, and a person reading the settings window can see what happened.
        if summary == nil {
            summary = reply.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
        }
        self.summary = summary.map { $0.count > 200 ? String($0.prefix(199)) + "…" : $0 }
        self.systems = systems
    }

    private static func value(of key: String, in line: String) -> String? {
        let lower = line.lowercased()
        guard lower.hasPrefix(key + ":") else { return nil }
        return String(line.dropFirst(key.count + 1))
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t*_`"))
    }

    /// What an agent is asked, once, when it is added.
    public static let question = """
    Two questions about yourself, for a list somebody is choosing from.

    Reply with exactly two lines and nothing else:

    SUMMARY: one sentence saying what you are for, as somebody deciding whether to send you a job \
    would want it — plain, specific, under twenty-five words.
    SYSTEMS: the systems you can actually reach, comma separated — the tools, services and accounts \
    you are connected to, such as Slack, GitHub, a calendar, a mailbox, a database. Only what you \
    genuinely have access to. Write `none` if you have no connections at all.
    """
}
