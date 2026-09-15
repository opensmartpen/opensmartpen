import Foundation

/// One thing said about an action: by you, or by the agent carrying it out.
///
/// The agent's message is the deliverable, not a progress note — "who Ondřej Široký is" is the
/// point of asking, and it belongs beside the line that asked for it rather than in a log.
public struct ActionMessage: Codable, Equatable {
    public enum From: String, Codable { case you, agent }

    public var from: From
    public var text: String
    public var at: Date

    public init(from: From, text: String, at: Date = Date()) {
        self.from = from
        self.text = text
        self.at = at
    }
}

/// A line the writer addressed to an assistant, and what has happened to it.
///
/// Small on purpose. `done` and `note` are the only things here that the page cannot say, and they
/// are the only things worth protecting: an action that has been carried out has changed something
/// in the world, and doing it twice is not free.
public struct PageAction: Codable, Equatable {
    public var text: String
    public var done: Bool
    /// Not going to happen: a line the reader made nonsense of, or one you have decided against.
    ///
    /// It is marked, never deleted. The line is still on the paper, so a reading would find it
    /// again and put it back — which makes "delete" a button that undoes itself a minute later.
    public var dismissed: Bool
    /// The last thing said about it, in one line, for a row that has no room for more.
    public var note: String?
    /// The whole exchange, oldest first. Empty until somebody asks the agent to do something.
    ///
    /// This, and not a session on the far side, is what the conversation is made of: a DAM session
    /// hibernates, and this Mac restarts, and neither of those should lose what was said. Each turn
    /// is sent the page, the reading and everything below, so the agent picks up where it left off
    /// whatever happened in between.
    public var thread: [ActionMessage]
    /// The DAM session the last turn ran in, so a run can be found on the far side. We do not
    /// depend on it; it is a pointer for a person.
    public var session: String?
    /// Which agent should carry it out. Proposed by the reader from the roster it is shown, and
    /// changed by a person whenever the guess is wrong. Nil means the reader itself, which is the
    /// agent with no connections — so an action nobody has routed can do nothing surprising.
    public var agent: String?

    public init(text: String, done: Bool = false, dismissed: Bool = false, note: String? = nil,
                thread: [ActionMessage] = [], session: String? = nil, agent: String? = nil) {
        self.agent = agent
        self.text = text
        self.done = done
        self.dismissed = dismissed
        self.note = note
        self.thread = thread
        self.session = session
    }

    /// Older files, and anything the agent writes without the field, have nothing dismissed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        dismissed = try c.decodeIfPresent(Bool.self, forKey: .dismissed) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note)
        thread = try c.decodeIfPresent([ActionMessage].self, forKey: .thread) ?? []
        session = try c.decodeIfPresent(String.self, forKey: .session)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
    }

    /// Waiting on you: the agent asked something and nothing has been said back.
    public var needsYou: Bool {
        state == .open && thread.last?.from == .agent
    }

    /// What the row looks like. Dismissed outranks done: something you have called off is called
    /// off whatever else is recorded about it.
    public enum State: Equatable { case open, done, dismissed }

    public var state: State {
        if dismissed { return .dismissed }
        return done ? .done : .open
    }

    /// Actions are matched between readings by what they say, with spacing and case ignored. No
    /// ids: the model would have to invent them and keep them stable, and this is the same join
    /// with nothing to go wrong in it. Two identical lines on one page count as one — a fair price.
    public var key: String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The actions on one page: read, written, and merged across readings.
public enum PageActions {
    /// Where one page's actions are kept: beside its reading, under the copy of the notebook it
    /// was written in. Three places want this path — the processor that writes the file, the
    /// viewer that shows a spread, the panel that lists what is outstanding — so it is worked out
    /// once here rather than three times from the same three parts.
    public static func url(root: URL, books: BookRegistry, for ref: PageRef) -> URL? {
        guard let book = books.record(for: ref) else { return nil }
        return root.appendingPathComponent(
            ref.folder.pagePath(stem: book.pageStem(ref.page.page), ext: "actions.json"))
    }

    /// One pair of coders for every crossing of this file — disk, and the agent's workspace.
    /// Dates as ISO 8601, because the file is opened and read by people.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// What the app keeps, and what the agent is shown.
    public static func load(_ url: URL) -> [PageAction] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([PageAction].self, from: data)) ?? []
    }

    /// Change one action in the file on disk, matched the way actions are always matched.
    ///
    /// Read, change, write — no locking. One person is clicking, and the agent's answers come back
    /// through `merge`, so there is no second writer to race with.
    @discardableResult
    public static func update(_ url: URL, key: String,
                              _ change: (inout PageAction) -> Void) throws -> [PageAction] {
        var actions = load(url)
        guard let i = actions.firstIndex(where: { $0.key == key }) else { return actions }
        change(&actions[i])
        try save(actions, to: url)
        return actions
    }

    public static func save(_ actions: [PageAction], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(actions).write(to: url, options: .atomic)
    }

    /// What the page says now, with what we know already having happened.
    ///
    /// The new list decides which actions exist and in what order — the paper is what says that.
    /// Ours decides whether one is done, and nothing in a later reading can undo it: the agent is
    /// asked to carry the flags forward, and this is what happens when it does not.
    public static func merge(ours: [PageAction], theirs: [PageAction]) -> [PageAction] {
        let known = Dictionary(ours.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = theirs.map { action -> PageAction in
            guard let mine = known[action.key] else { return action }
            var kept = action
            // What we know beats what the reading proposes, in one direction only. `done` and
            // `dismissed` are facts about the world and about your decisions; a reading is a
            // proposal about a piece of paper, and it cannot undo either. Undoing is a click,
            // not something a model can do on your behalf.
            kept.done = mine.done || action.done
            kept.dismissed = mine.dismissed || action.dismissed
            kept.note = mine.note ?? action.note
            // The conversation is ours. A reading of the paper knows nothing about it and cannot
            // be allowed to drop it.
            kept.thread = mine.thread
            kept.session = mine.session ?? action.session
            // Whoever it was routed to, it stays routed to. The first reading proposes an agent;
            // after that the answer is either that proposal or a person's correction of it, and a
            // later reading of the same paper is in no better position to judge than either.
            kept.agent = mine.agent ?? action.agent
            return kept
        }
        // An action we have carried out, or called off, that the new reading does not mention —
        // the line was rewritten, or the reader missed it. It stays: it happened, or it was
        // decided, and neither of those is undone by a reading that failed to see the line.
        let seen = Set(merged.map(\.key))
        merged.append(contentsOf: ours.filter { ($0.done || $0.dismissed) && !seen.contains($0.key) })
        return merged
    }
}
