import Foundation

/// Makes the picture of a page that the agent reads. The drawing needs Core Graphics, which this
/// layer does not have, so it arrives from above.
public protocol PageImaging: AnyObject {
    func png(for ref: PageRef) -> Data?
}

/// Hands a finished page to a DAM agent to be read, and files what comes back.
///
/// The round trip is four steps and no state: draw the page, put the image in the agent's
/// workspace beside whatever reading it already has, ask for a reading, write the answer next to
/// the captured strokes. What is outstanding is never remembered — a page needs reading when its
/// captured file is newer than its reading, which is a question the files answer after a restart
/// as well as before one (ADR-004).
///
/// The window is short, a minute by default, and separate from the publish window for a reason: a
/// commit is a record and can wait, while a reading is what a person looks at. A page written on
/// again is simply read again; the Markdown is derived and costs one turn to make.
public final class PageProcessor {
    private let books: BookRegistry
    private let root: URL
    private let imaging: PageImaging
    private let fleet: DamFleet
    private let notifier: Notifier
    /// How long a page must be still before it is sent.
    public var quietWindow: TimeInterval
    /// What the agent is asked to do. Nil uses `PagePrompt.standard`.
    public var prompt: String?
    /// Books that are control surfaces; their taps are commands, never pages to read.
    public var controlBooks: Set<String> = []
    /// The agents an action may be handed to, as they describe themselves. Shown to the reader so
    /// it can propose one per line; shown to a person so they can correct it. Empty means every
    /// action goes to the reader, which is the agent with nothing to reach.
    public var roster: [DamAgentProfile] = []
    /// Fired on the main queue after every attempt, so a panel can show what happened.
    public var onChange: (() -> Void)?

    public private(set) var lastRead: (page: PageRef, at: Date)?
    public private(set) var consecutiveFailures = 0
    public private(set) var lastError: String?
    private var nextRetry: Date = .distantPast
    private var inFlight = false

    public init(books: BookRegistry, root: URL, imaging: PageImaging, fleet: DamFleet,
                notifier: Notifier, quietWindow: TimeInterval = 60) {
        self.books = books
        self.root = root
        self.imaging = imaging
        self.fleet = fleet
        self.notifier = notifier
        self.quietWindow = quietWindow
    }

    /// One agent for everything: what this was before a page could be routed anywhere.
    public convenience init(books: BookRegistry, root: URL, imaging: PageImaging,
                            workspace: DamWorkspace, runner: DamPrompting, notifier: Notifier,
                            quietWindow: TimeInterval = 60) {
        self.init(books: books, root: root, imaging: imaging,
                  fleet: OneAgent(prompter: runner, workspace: workspace), notifier: notifier,
                  quietWindow: quietWindow)
    }

    public var isReading: Bool { inFlight }
    /// When the next attempt is due after a failure; nil when nothing is being backed off.
    public var nextRetryAt: Date? { nextRetry == .distantPast ? nil : nextRetry }

    // MARK: - What needs reading

    /// Pages whose strokes have settled and whose reading is older than they are.
    ///
    /// Oldest first: a page that has been waiting longest is the one somebody is most likely to be
    /// looking for.
    public func due(now: Date = Date()) -> [PageRef] { due(now: now, after: quietWindow) }

    /// Everything whose reading is out of date, however recently it was written — what the panel
    /// offers to send at once when somebody does not want to wait out the minute.
    public var outstanding: [PageRef] { due(now: Date(), after: 0) }

    private func due(now: Date, after window: TimeInterval) -> [PageRef] {
        books.recentPages(limit: 500)
            .filter { entry in
                guard !controlBooks.contains(entry.page.folder.surface) else { return false }
                guard now.timeIntervalSince(entry.written) >= window else { return false }
                guard let reading = readingURL(for: entry.page) else { return false }
                let read = (try? reading.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                return read.map { entry.written > $0 } ?? true
            }
            .map(\.page)
            .reversed()
    }

    /// Where a page's reading is kept: beside the captured file it was made from, under the same
    /// name (ADR-002). Nil when the notebook has no record, which means nothing is known about it
    /// yet and there is nothing to name the file after.
    public func readingURL(for ref: PageRef) -> URL? {
        guard let book = books.record(for: ref) else { return nil }
        return root.appendingPathComponent(ref.folder.pagePath(stem: book.pageStem(ref.page.page), ext: "md"))
    }

    /// Where a page's actions are kept: beside its reading, and owned by us rather than by the
    /// agent. An action that has been carried out has changed something in the world, so its state
    /// is not derived and is never thrown away when the page is read again.
    public func actionsURL(for ref: PageRef) -> URL? {
        PageActions.url(root: root, books: books, for: ref)
    }

    /// Where the same page lives for the agent that reads it. Flat, one folder per copy, named as
    /// the copy is named here — so a person looking at either side sees the same notebook.
    ///
    /// The agent's own sessions run in `~/work`, so this is the path to put in a prompt.
    func agentPath(for ref: PageRef, ext: String) -> String {
        let stem = books.record(for: ref)?.pageStem(ref.page.page) ?? "p\(ref.page.page)"
        return "pen/\(ref.folder.name)/\(stem).\(ext)"
    }

    /// The same file, as the file API addresses it.
    ///
    /// The two differ, and the difference is the whole of a bug worth remembering: the file API is
    /// rooted at the agent's home, while a session runs one directory down in `work`. Uploading to
    /// `pen/…` puts the page somewhere the agent never looks, and the agent says so politely by
    /// writing nothing.
    func workspacePath(for ref: PageRef, ext: String) -> String {
        Self.workRoot + agentPath(for: ref, ext: ext)
    }

    /// What the file API has to be given to reach the directory a session starts in.
    public static let workRoot = "work/"

    // MARK: - The round trip

    /// Send one page and file the answer. One at a time: a turn is serial on the agent anyway, and
    /// a queue here would only hide that.
    public func tick(now: Date = Date()) {
        guard !inFlight else { return }
        if sweeping {
            guard let page = outstanding.first else {
                sweeping = false
                return
            }
            send(page, now: now)
            return
        }
        guard now >= nextRetry, let page = due(now: now).first else { return }
        send(page, now: now)
    }

    /// Read everything that is owed a reading, starting now: no waiting for a page to go still, and
    /// no waiting out a backoff. Asked for by a person who can see the pages waiting and has
    /// decided not to wait for them.
    ///
    /// One page at a time, oldest first, one per tick — an agent runs one turn at a time, so a
    /// queue here would only hide how long it takes. A failure ends the sweep: six failures in a
    /// row is a broken connection reported six times, and the backoff exists to stop that.
    public func readNow(now: Date = Date()) {
        sweeping = true
        nextRetry = .distantPast
        tick(now: now)
    }

    /// How many pages the sweep has left, which is what the panel counts.
    public var outstandingCount: Int { outstanding.count }

    /// True from the moment a person asks until nothing is owed or something fails.
    public private(set) var sweeping = false

    private func send(_ page: PageRef, now: Date) {
        inFlight = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await read(page)
                await finish(.success(page), now: now)
            } catch {
                await finish(.failure(error), now: now)
            }
        }
    }

    /// Everything the agent is given about one page: the picture, our reading of it, and what we
    /// know about its actions. The same parcel whether it is being read or being acted on — an
    /// action carried out without the page in front of it is an instruction with no context.
    private struct Staged {
        let png: Data
        let actions: [PageAction]
    }

    @discardableResult
    private func stage(_ ref: PageRef, agent: String? = nil) async throws -> Staged {
        guard let png = imaging.png(for: ref) else { throw ReadError.nothingToDraw(ref) }
        let workspace = try fleet.workspace(for: agent)
        try await workspace.upload(path: workspacePath(for: ref, ext: "png"), data: png,
                                   contentType: "image/png", overwrite: true)

        // The reading we already have goes with it, when there is one. The page is the same paper
        // as before plus whatever was added, so the agent should correct its own earlier reading
        // rather than start again — which is how it can tell what is new.
        if let existing = readingURL(for: ref), let data = try? Data(contentsOf: existing) {
            try await workspace.upload(path: workspacePath(for: ref, ext: "md"), data: data,
                                       contentType: "text/markdown", overwrite: true)
        }
        // And the actions, which matter more: they say what has already been carried out, and what
        // has been called off, so the agent knows not to offer either again.
        let ours = actionsURL(for: ref).map { PageActions.load($0) } ?? []
        if !ours.isEmpty, let data = try? PageActions.encoder.encode(ours) {
            try await workspace.upload(path: workspacePath(for: ref, ext: "actions.json"), data: data,
                                       contentType: "application/json", overwrite: true)
        }
        return Staged(png: png, actions: ours)
    }

    /// Take back what the agent wrote to the actions file and put our own knowledge over the top.
    private func collectActions(for ref: PageRef, ours: [PageAction]) async throws {
        guard let actions = actionsURL(for: ref) else { return }
        let workspace = try fleet.workspace(for: nil)
        let theirs = (try? await workspace.read(path: workspacePath(for: ref, ext: "actions.json")))
            .flatMap { (try? PageActions.decoder.decode([PageAction].self, from: $0.data)) } ?? []
        let merged = PageActions.merge(ours: ours, theirs: theirs)
        if !merged.isEmpty || !ours.isEmpty { try PageActions.save(merged, to: actions) }
    }

    /// Draw the page, hand it over, ask for a reading, and write back what the agent wrote.
    public func read(_ ref: PageRef) async throws {
        let readingPath = workspacePath(for: ref, ext: "md")
        // What the agent is told to open, which is the same file one directory shallower.
        let imageForAgent = agentPath(for: ref, ext: "png")
        let readingForAgent = agentPath(for: ref, ext: "md")
        let staged = try await stage(ref)
        let png = staged.png
        let ours = staged.actions

        let text = prompt ?? PagePrompt.standard(image: imageForAgent, reading: readingForAgent,
                                                 actions: agentPath(for: ref, ext: "actions.json"),
                                                 label: books.label(for: ref).oneLine,
                                                 roster: roster)
        let outcome = try await fleet.prompter(for: nil)
            .run(prompt: text, image: DamImage(data: png, mimeType: "image/png"), timeout: 900)
        Log.info("agent read \(ref) (\(outcome.stopReason ?? "no stop reason"))")

        let file = try await fleet.workspace(for: nil).read(path: readingPath)
        guard let reading = readingURL(for: ref) else { throw ReadError.noRecord(ref) }
        try FileManager.default.createDirectory(at: reading.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try file.data.write(to: reading, options: .atomic)

        // The actions come back as a proposal — what the page says now. What we knew about them is
        // merged over the top, because a model that forgets a flag would send the same email twice.
        try await collectActions(for: ref, ours: ours)
    }

    // MARK: - Carrying one out

    /// Ask the agent to carry out one line, with the page in front of it.
    ///
    /// Not part of the sweep and never automatic: a `>>` line is done when a person clicks it. The
    /// answer comes back in the same actions file — ticked, or left open with one sentence saying
    /// what stopped it — and is merged in the usual way.
    ///
    /// `guidance` is whatever you typed into the box: the thing the paper does not say, because
    /// "send this to Tomáš" leaves out which Tomáš.
    ///
    /// The completion runs on the main queue. One turn at a time, like reading, and for the same
    /// reason: the agent is serial, and a queue here would only hide it.
    public func execute(action: PageAction, on ref: PageRef, say: String? = nil,
                        completion: @escaping (Error?) -> Void) {
        guard !inFlight else {
            completion(ExecuteError.busy)
            return
        }
        inFlight = true
        running = (page: ref, key: action.key)
        onChange?()
        Task { [weak self] in
            guard let self else { return }
            var failure: Error?
            do { try await carryOut(action, on: ref, say: say) } catch { failure = error }
            await self.finishRun(failure, completion: completion)
        }
    }

    /// The action being carried out right now, if any.
    public private(set) var running: (page: PageRef, key: String)?

    public enum ExecuteError: Error, LocalizedError {
        case busy

        public var errorDescription: String? {
            "The agent is busy with another page. Try again in a moment."
        }
    }

    private func carryOut(_ action: PageAction, on ref: PageRef, say: String?) async throws {
        let url = actionsURL(for: ref)
        // Yours goes in before the turn starts. A turn can fail, and what you typed is not
        // something to lose to a dropped socket — and it is also what the agent is about to read.
        var thread = action.thread
        if let mine = say?.trimmingCharacters(in: .whitespacesAndNewlines), !mine.isEmpty {
            let message = ActionMessage(from: .you, text: mine)
            thread.append(message)
            if let url { try? PageActions.update(url, key: action.key) { $0.thread.append(message) } }
        }

        // The page goes to whoever is carrying the line out, not to the reader. That is the whole
        // point of the roster: the agent that looks at the paper has no connections, and the agent
        // with the connections is never shown a page it was not routed to.
        let staged = try await stage(ref, agent: action.agent)
        let text = PagePrompt.execute(action: action.text, thread: thread,
                                      image: agentPath(for: ref, ext: "png"),
                                      reading: agentPath(for: ref, ext: "md"),
                                      label: books.label(for: ref).oneLine)
        // Carried on where it left off, when there is a session to carry on from: the agent keeps
        // what it worked out last time, and the exchange above is the part that survives a pod
        // being restarted underneath us.
        let outcome = try await fleet.prompter(for: action.agent)
            .run(prompt: text, image: DamImage(data: staged.png, mimeType: "image/png"),
                 resume: action.session, timeout: 900)
        let answer = ActionAnswer(outcome.text)
        Log.info("agent worked on \(ref): \(action.text) — \(answer.status) "
                 + "(\(outcome.stopReason ?? "no stop reason"))")
        guard let url else { return }
        try PageActions.update(url, key: action.key) {
            $0.thread.append(ActionMessage(from: .agent, text: answer.text))
            $0.note = answer.summary
            $0.session = outcome.sessionId
            // Only the agent's own word for it, and only in one direction. It cannot un-tick
            // something, and it cannot call anything off.
            if answer.status == .done { $0.done = true }
        }
    }

    @MainActor
    private func finishRun(_ failure: Error?, completion: @escaping (Error?) -> Void) {
        inFlight = false
        running = nil
        if let failure { Log.error("carrying out an action failed: \(failure)") }
        completion(failure)
        onChange?()
    }

    public enum ReadError: Error, LocalizedError {
        case nothingToDraw(PageRef)
        case noRecord(PageRef)

        public var errorDescription: String? {
            switch self {
            case let .nothingToDraw(ref): return "\(ref) has no ink to draw"
            case let .noRecord(ref): return "\(ref) belongs to no notebook on disk"
            }
        }
    }

    @MainActor
    private func finish(_ result: Result<PageRef, Error>, now: Date) {
        inFlight = false
        switch result {
        case let .success(page):
            lastRead = (page, now)
            if consecutiveFailures > 0 {
                notifier.post(Notice(key: "read-recovered", title: "Brainio Pen is reading pages again",
                                     body: "The agent answered."))
            }
            consecutiveFailures = 0
            lastError = nil
            nextRetry = .distantPast
        case let .failure(error):
            consecutiveFailures += 1
            lastError = "\(error)"
            sweeping = false
            // Back off 1, 2, 4, … minutes, capped at 30 — the same discipline as publishing, for
            // the same reason: a server that is down stays down for a while.
            nextRetry = now.addingTimeInterval(min(30, pow(2, Double(consecutiveFailures - 1))) * 60)
            Log.error("reading a page failed (\(consecutiveFailures)x): \(error)")
            if consecutiveFailures >= 3 {
                notifier.post(Notice(key: "read-failed", title: "Brainio Pen cannot get pages read",
                                     body: "\(consecutiveFailures) attempts failed. The strokes are safe on disk. "
                                         + "Last error: \(error.localizedDescription)"))
            }
        }
        onChange?()
    }
}

/// What the agent is asked to do with a page.
///
/// It lives here rather than on the agent because it changes with the app: the paths, the marker
/// for a command, and what the frontmatter has to carry are all decided on this side. The rules
/// themselves are ADR-DRAFT-image-transcription — reproduce, never improve, and say plainly what
/// could not be read.
public enum PagePrompt {
    public static func standard(image: String, reading: String, actions: String,
                                label: String, roster: [DamAgentProfile] = []) -> String {
        // Who could carry each line out. The reader never carries one out itself — it is chosen
        // for having no connections — so this is a guess for a person to check, not a hand-over.
        let routing = roster.isEmpty ? "" : """
        \n
        Add `"agent"` to each entry: the id of whichever assistant below is best able to carry that \
        line out, or `null` when none of them plainly fits. Go by what each one can reach — a line \
        about a Slack message needs the one connected to Slack. Guess once; a person checks it.

        \(roster.map(\.roster).joined(separator: "\n"))
        """

        return """
        The page is attached to this message. Read it and write the result to `\(reading)`.

        It is page \(label), captured from a smartpen. The image is the record; the text you write \
        is a lead, and anything you are unsure of must say so.

        Read the attached picture directly. It is already cropped to the writing and drawn large \
        enough to read, so do not open, crop, magnify or convert it, and do not install anything to \
        do so — a word you cannot read is marked, not recovered. The same picture is in the \
        workspace as `\(image)` if you ever need the file itself.

        Rules:
        - Reproduce what is written, in its original language (Czech or English). Do not translate.
        - Read a difficult word from its context when the context makes it plain. Mark one you \
        genuinely cannot make out as `[?]`.
        - Keep the structure the writer used: headings, lists, numbering, indentation, checkboxes.
        - Describe a drawing in one italic line, like *[diagram: three boxes joined by arrows]*, \
        rather than trying to draw it.
        - Ignore printed page furniture: rules, dot grids, margins, printed page numbers.
        - Write the page and nothing about the reading of it. No notes on letter shapes, on what \
        you compared, or on how sure you are: a reader wants the page, not your working.
        - A line that opens with `>>` is an instruction to an assistant. Write it as an unchecked \
        task: `- [ ] >> …`. Do not do what it says. This is a reading, not an errand.
        - Where the writing plainly changes subject, put a `---` between the two parts. One sheet \
        of paper often holds two unrelated sittings.

        If `\(reading)` already exists, it is your own earlier reading of the same sheet, which has \
        since been written on. Correct and extend it rather than starting again, and keep the state \
        of any task that is already ticked.

        Write the file with frontmatter naming the page, the source image and the model that read \
        it.

        Then write `\(actions)`: a JSON array holding one entry per `>>` line, each \
        `{"text": "the line without the >>", "done": false, "dismissed": false, "note": null}`.\
        \(routing)
        If \
        that file is already there, it is the record of what has already been carried out and what \
        has been called off: keep every entry it holds that is still on the page exactly as it is, \
        `done`, `dismissed` and `note` untouched, and add only what the new writing added. Carry \
        out none of them — this is a reading, not an errand.

        Reply with one line saying what you did.
        """
    }

    /// One line, to be carried out now, with the page it was written on attached and whatever has
    /// already been said about it.
    ///
    /// The opposite instruction to `standard` in one respect only: this one is an errand. Every
    /// other line on the page stays untouched, because a person clicked one of them and not the
    /// rest.
    ///
    /// It writes no files. The reply *is* the answer — the thing you asked to find out — and the
    /// app files it beside the line that asked. One status line at the end is all the app reads,
    /// and the only part of the reply it acts on.
    public static func execute(action: String, thread: [ActionMessage], image: String,
                               reading: String, label: String) -> String {
        var parts = ["""
        Carry out this one instruction, written by hand on page \(label):

            \(action)
        """]

        if !thread.isEmpty {
            let said = thread.map { message in
                "\(message.from == .you ? "The person who asked" : "You"): \(message.text)"
            }.joined(separator: "\n\n")
            parts.append("""
            What has been said about it so far, oldest first. Anything the person told you \
            outranks the page, which is short of context by nature:

            \(said)
            """)
        }

        parts.append("""
        The page is attached so you can see what the line was written beside. Read it directly — do \
        not open, crop, magnify or convert it, and do not install anything. The same picture is in \
        the workspace as `\(image)`, and your own reading of the page is `\(reading)`.

        Do that one thing and nothing else. The page holds other instructions; leave them alone. \
        Write no files: the reply is the answer, and it is filed next to the line that asked for it.

        Reply with the answer itself — what you found, what you sent, what you drafted — in as much \
        detail as it deserves and no more. If you cannot finish, say plainly what is in the way: \
        ask the question you need answered, and nothing else.

        End your reply with one line, exactly one of these and nothing after it:

        STATUS: done — you carried it out, and the answer is above.
        STATUS: needs-info — you need something only the person can tell you.
        STATUS: blocked — it cannot be done from where you are.
        """)

        return parts.joined(separator: "\n\n")
    }
}
