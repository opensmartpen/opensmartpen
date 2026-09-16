import Foundation

/// Makes the picture of a page that the agent transcribes. The drawing needs Core Graphics, which this
/// layer does not have, so it arrives from above.
public protocol PageImaging: AnyObject {
    func png(for ref: PageRef) -> Data?
}

/// Hands a finished page to a DAM agent to be transcribed, and files what comes back.
///
/// The round trip is four steps and no state: draw the page, put the image in the agent's
/// workspace beside whatever transcript it already has, ask for a transcript, write the answer next to
/// the captured strokes. What is outstanding is never remembered — a page needs transcribing when its
/// captured file is newer than its transcript, which is a question the files answer after a restart
/// as well as before one (ADR-004).
///
/// The window is short, a minute by default, and separate from the publish window for a reason: a
/// commit is a record and can wait, while a transcript is what a person looks at. A page written on
/// again is simply transcribed again; the Markdown is derived and costs one turn to make.
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
    /// Books that are control surfaces; their taps are commands, never pages to transcribe.
    public var controlBooks: Set<String> = []
    /// The agents an action may be handed to, as they describe themselves. Shown to the transcriber so
    /// it can propose one per line; shown to a person so they can correct it. Empty means every
    /// action goes to the transcriber, which is the agent with nothing to reach.
    public var roster: [DamAgentProfile] = []
    /// Fired on the main queue after every attempt, so a panel can show what happened.
    public var onChange: (() -> Void)?

    public private(set) var lastTranscribed: (page: PageRef, at: Date)?
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

    /// A page is being transcribed. Carrying a line out is counted separately: several can be in the
    /// air at once, and none of them is a transcript.
    public var isTranscribing: Bool { inFlight }
    /// When the next attempt is due after a failure; nil when nothing is being backed off.
    public var nextRetryAt: Date? { nextRetry == .distantPast ? nil : nextRetry }

    // MARK: - What needs transcribing

    /// Pages whose strokes have settled and whose transcript is older than they are.
    ///
    /// Oldest first: a page that has been waiting longest is the one somebody is most likely to be
    /// looking for.
    public func due(now: Date = Date()) -> [PageRef] { due(now: now, after: quietWindow) }

    /// Everything whose transcript is out of date, however recently it was written — what the panel
    /// offers to send at once when somebody does not want to wait out the minute.
    public var outstanding: [PageRef] { due(now: Date(), after: 0) }

    private func due(now: Date, after window: TimeInterval) -> [PageRef] {
        books.recentPages(limit: 500)
            .filter { entry in
                guard !controlBooks.contains(entry.page.folder.surface) else { return false }
                guard now.timeIntervalSince(entry.written) >= window else { return false }
                guard let transcript = transcriptURL(for: entry.page) else { return false }
                let transcribed = (try? transcript.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                return transcribed.map { entry.written > $0 } ?? true
            }
            .map(\.page)
            .reversed()
    }

    /// Where a page's transcript is kept: beside the captured file it was made from, under the same
    /// name (ADR-002). Nil when the notebook has no record, which means nothing is known about it
    /// yet and there is nothing to name the file after.
    public func transcriptURL(for ref: PageRef) -> URL? {
        guard let book = books.record(for: ref) else { return nil }
        return root.appendingPathComponent(ref.folder.pagePath(stem: book.pageStem(ref.page.page), ext: "md"))
    }

    /// Where a page's actions are kept: beside its transcript, and owned by us rather than by the
    /// agent. An action that has been carried out has changed something in the world, so its state
    /// is not derived and is never thrown away when the page is transcribed again.
    public func actionsURL(for ref: PageRef) -> URL? {
        PageActions.url(root: root, books: books, for: ref)
    }

    /// Where the same page lives for the agent that transcribes it. Flat, one folder per copy, named as
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

    /// Transcribe everything that is owed a transcript, starting now: no waiting for a page to go still, and
    /// no waiting out a backoff. Asked for by a person who can see the pages waiting and has
    /// decided not to wait for them.
    ///
    /// One page at a time, oldest first, one per tick — an agent runs one turn at a time, so a
    /// queue here would only hide how long it takes. A failure ends the sweep: six failures in a
    /// row is a broken connection reported six times, and the backoff exists to stop that.
    public func transcribeNow(now: Date = Date()) {
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
                try await transcribe(page)
                await finish(.success(page), now: now)
            } catch {
                await finish(.failure(error), now: now)
            }
        }
    }

    /// Everything the agent is given about one page: the picture, our transcript of it, and what we
    /// know about its actions. The same parcel whether it is being transcribed or being acted on — an
    /// action carried out without the page in front of it is an instruction with no context.
    private struct Staged {
        let png: Data
        let actions: [PageAction]
    }

    @discardableResult
    private func stage(_ ref: PageRef, agent: String? = nil) async throws -> Staged {
        guard let png = imaging.png(for: ref) else { throw TranscribeError.nothingToDraw(ref) }
        let workspace = try fleet.workspace(for: agent)
        try await workspace.upload(path: workspacePath(for: ref, ext: "png"), data: png,
                                   contentType: "image/png", overwrite: true)

        // The transcript we already have goes with it, when there is one. The page is the same paper
        // as before plus whatever was added, so the agent should correct its own earlier transcript
        // rather than start again — which is how it can tell what is new.
        if let existing = transcriptURL(for: ref), let data = try? Data(contentsOf: existing) {
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

    /// Draw the page, hand it over, ask for a transcript, and write back what the agent wrote.
    public func transcribe(_ ref: PageRef) async throws {
        let transcriptPath = workspacePath(for: ref, ext: "md")
        // What the agent is told to open, which is the same file one directory shallower.
        let imageForAgent = agentPath(for: ref, ext: "png")
        let transcriptForAgent = agentPath(for: ref, ext: "md")
        let staged = try await stage(ref)
        let png = staged.png
        let ours = staged.actions

        let text = prompt ?? PagePrompt.standard(image: imageForAgent, transcript: transcriptForAgent,
                                                 actions: agentPath(for: ref, ext: "actions.json"),
                                                 label: books.label(for: ref).oneLine,
                                                 roster: roster)
        let outcome = try await fleet.prompter(for: nil)
            .run(prompt: text, image: DamImage(data: png, mimeType: "image/png"), timeout: 900)
        Log.info("agent transcribed \(ref) (\(outcome.stopReason ?? "no stop reason"))")

        let file = try await fleet.workspace(for: nil).read(path: transcriptPath)
        guard let transcript = transcriptURL(for: ref) else { throw TranscribeError.noRecord(ref) }
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try file.data.write(to: transcript, options: .atomic)

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
    /// The completion runs on the main queue. One turn at a time, like transcribing, and for the same
    /// reason: the agent is serial, and a queue here would only hide it.
    public func execute(action: PageAction, on ref: PageRef, say: String? = nil,
                        completion: @escaping (Error?) -> Void) {
        // Only the same line twice over. Two different lines run at once on purpose: they are
        // often two different agents, and even on one agent DAM queues them — which is a better
        // place for a queue than here, where it would look like the app had stopped.
        guard !running.contains(action.key) else {
            completion(ExecuteError.busy)
            return
        }
        running.insert(action.key)
        let desk = makeDesk(for: action)
        desks[action.key] = desk
        onChange?()
        Task { [weak self] in
            guard let self else { return }
            var failure: Error?
            do { try await carryOut(action, on: ref, say: say, desk: desk) } catch { failure = error }
            await self.finishRun(action.key, failure, completion: completion)
        }
    }

    /// The lines being carried out right now, by key.
    public private(set) var running: Set<String> = []

    // MARK: - Fixing the wording

    /// Ask the transcriber to change how the page's lines are worded — "lowercase", "the name is Ondřej
    /// Široký" — with the page in front of it, so a name is checked against the handwriting rather
    /// than guessed at.
    ///
    /// The transcriber, and not the agent a line is routed to: this is about what the paper says, which
    /// is the transcriber's job, and it must not be a chance to carry anything out. Every line keeps its
    /// record — what was said, which session, whether it is done — because the words changed and
    /// the errand did not.
    ///
    /// The completion runs on the main queue, like `execute`.
    public func reword(_ ref: PageRef, instruction: String, completion: @escaping (Error?) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            let failure: Error?
            do { try await self.rewordLines(on: ref, instruction: instruction); failure = nil } catch { failure = error }
            if let failure { Log.error("fixing the wording failed: \(failure)") }
            let outcome = failure
            await MainActor.run {
                completion(outcome)
                self.onChange?()
            }
        }
    }

    private func rewordLines(on ref: PageRef, instruction: String) async throws {
        let staged = try await stage(ref)
        let before = staged.actions
        guard !before.isEmpty, let url = actionsURL(for: ref) else { return }

        let text = PagePrompt.reword(lines: before.map(\.text), instruction: instruction,
                                     image: agentPath(for: ref, ext: "png"),
                                     label: books.label(for: ref).oneLine)
        let outcome = try await fleet.prompter(for: nil)
            .run(prompt: text, image: DamImage(data: staged.png, mimeType: "image/png"), timeout: 300)
        let after = try Self.rewordedLines(in: outcome.text, count: before.count)
        Log.info("transcriber reworded \(ref): \(instruction)")

        // Matched by key and not by position: the file may have gained a line while the turn ran.
        // A line the transcriber left alone, or blanked, is left alone here.
        try PageActions.revise(url) { actions in
            for (old, new) in zip(before, after) {
                let words = new.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !words.isEmpty, words != old.text,
                      let i = actions.firstIndex(where: { $0.key == old.key }) else { continue }
                actions[i].paper = actions[i].paper ?? actions[i].text
                actions[i].text = words
            }
        }
    }

    /// The reply is a JSON array of strings, one per line, and nothing else — but a model that has
    /// been told that will still sometimes wrap it in a sentence or a code fence, so the array is
    /// cut out from the first bracket to the last.
    static func rewordedLines(in reply: String, count: Int) throws -> [String] {
        guard let open = reply.firstIndex(of: "["), let close = reply.lastIndex(of: "]"), open < close,
              let data = String(reply[open...close]).data(using: .utf8),
              let lines = try? JSONDecoder().decode([String].self, from: data) else {
            throw RewordError.notAList
        }
        guard lines.count == count else { throw RewordError.wrongCount(got: lines.count, wanted: count) }
        return lines
    }

    public enum RewordError: Error, LocalizedError {
        case notAList
        case wrongCount(got: Int, wanted: Int)

        public var errorDescription: String? {
            switch self {
            case .notAList:
                return "The transcriber did not answer with the lines. Nothing was changed."
            case let .wrongCount(got, wanted):
                return "The transcriber sent back \(got) lines for \(wanted). Nothing was changed."
            }
        }
    }

    // MARK: - What the agent is waiting to be allowed to do

    /// One desk per line in the air. A line that is not running has none: the question only exists
    /// while the turn that asked it does.
    private var desks: [String: ApprovalDesk] = [:]

    /// What is waiting on somebody, for one line.
    public func waiting(on key: String) -> [ApprovalAsk] { desks[key]?.waiting ?? [] }

    /// Whether anything at all is waiting on a person.
    public var isWaitingOnYou: Bool { desks.values.contains { $0.isWaiting } }

    /// Yes, yes-from-now-on, or no.
    ///
    /// Two different places take the answer and neither of them is here: a tool call goes back
    /// down the socket the run is holding open, and an egress hold goes to DAM's approvals queue,
    /// where the gate is waiting on it. The desk knows which.
    public func decide(_ ask: ApprovalAsk, on key: String, _ verdict: ApprovalVerdict) async throws {
        guard let desk = desks[key] else { throw ApprovalError.gone }
        try await desk.decide(ask, verdict)
    }

    private func makeDesk(for action: PageAction) -> ApprovalDesk {
        // The queue is owner-wide, so any agent's connection reaches it; this one is the agent
        // whose run is being held up, which is the one a log should name.
        let queue = (try? fleet.approvals(for: action.agent)) ?? nil
        let desk = ApprovalDesk(gate: queue.map { queue in
            { id, verdict in try await queue.decide(approvalId: id, verdict: verdict) }
        })
        desk.onChange = { [weak self] in self?.approvalsChanged(for: action) }
        return desk
    }

    /// A question has arrived or been answered.
    ///
    /// The notice matters more than the refresh: the window is usually shut, the agent is stopped
    /// until somebody answers, and DAM holds the request for half an hour and then says no.
    private func approvalsChanged(for action: PageAction) {
        for ask in desks[action.key]?.waiting ?? [] {
            notifier.post(Notice(key: "approval-\(ask.id)",
                                 title: "The agent needs your say-so",
                                 body: "\(ask.title) — for “\(action.text)”"))
        }
        onChange?()
    }

    public enum ExecuteError: Error, LocalizedError {
        case busy

        public var errorDescription: String? {
            "That one is already running. Wait for it to answer."
        }
    }

    private func carryOut(_ action: PageAction, on ref: PageRef, say: String?,
                          desk: ApprovalDesk? = nil) async throws {
        let url = actionsURL(for: ref)
        // Yours goes in before the turn starts. A turn can fail, and what you typed is not
        // something to lose to a dropped socket — and it is also what the agent is about to read.
        var thread = action.thread
        if let mine = say?.trimmingCharacters(in: .whitespacesAndNewlines), !mine.isEmpty {
            let message = ActionMessage(from: .you, text: mine)
            thread.append(message)
            if let url { try? PageActions.update(url, key: action.key) { $0.thread.append(message) } }
        }

        // The page goes to whoever is carrying the line out, not to the transcriber. That is the whole
        // point of the roster: the agent that looks at the paper has no connections, and the agent
        // with the connections is never shown a page it was not routed to.
        //
        // The first turn puts the page in the agent's workspace. A later one does not: the files
        // are already there under the same names, and uploading them again buys nothing.
        let png: Data
        if action.session == nil {
            png = try await stage(ref, agent: action.agent).png
        } else {
            guard let drawn = imaging.png(for: ref) else { throw TranscribeError.nothingToDraw(ref) }
            png = drawn
        }

        let whole = PagePrompt.execute(action: action.text, thread: thread,
                                       image: agentPath(for: ref, ext: "png"),
                                       transcript: agentPath(for: ref, ext: "md"),
                                       label: books.label(for: ref).oneLine)
        let justThis = PagePrompt.carryOn(message: say)

        // What is said depends on whether the agent still has the conversation, which is not known
        // until the session is settled — so the runner asks for it then.
        //
        // Carried on: one line, because the agent already holds the errand, the page and every
        // word either of us has said. Sending them again would have it read its own conversation
        // twice, and it is paying for both copies.
        //
        // Started again: the whole errand, because the session is gone and this agent has never
        // seen any of it. That happens when the pod restarts, and it is why the app keeps the
        // exchange in its own file rather than trusting the agent to remember.
        let outcome = try await fleet.prompter(for: action.agent)
            .run(turn: { resumed in
                     resumed ? DamTurn(prompt: justThis)
                             : DamTurn(prompt: whole,
                                       image: DamImage(data: png, mimeType: "image/png"))
                 },
                 resume: action.session, timeout: 900, approvals: desk)
        let answer = ActionAnswer(outcome.text)
        Log.info("agent worked on \(ref): \(action.text) — \(answer.status) "
                 + "(\(outcome.stopReason ?? "no stop reason"))")
        guard let url else { return }
        // A turn that ended with nothing said still has to say something here. It happens — the
        // agent writes only the status line, or stops without a word — and an empty message in the
        // thread reads on screen as a broken app rather than as a quiet agent.
        //
        // When the harness says why it stopped, say that instead of guessing. `max_tokens` is the
        // one worth naming: the turn was cut off at its limit, which is somebody else's setting to
        // raise and nothing the person can fix by asking again more politely.
        let said = answer.text.isEmpty ? Self.nothingSaid(outcome.stopReason) : answer.text
        try PageActions.update(url, key: action.key) {
            $0.thread.append(ActionMessage(from: .agent, text: said, status: answer.status))
            $0.note = answer.summary ?? said
            $0.session = outcome.sessionId
            // Only the agent's own word for it, and only in one direction. It cannot un-tick
            // something, and it cannot call anything off.
            if answer.status == .done { $0.done = true }
        }
    }

    /// What to put in the thread when the agent said nothing at all.
    static func nothingSaid(_ stopReason: String?) -> String {
        switch stopReason {
        case "max_tokens":
            return "The turn was cut off at its token limit before the agent said anything. "
                + "The agent's output limit is too low for this — raise it in DAM."
        case "refusal":
            return "The agent declined to answer."
        case "cancelled":
            return "The turn was stopped before the agent said anything."
        default:
            return "The agent finished without saying anything. Continue with it, or say more about "
                + "what you want."
        }
    }

    @MainActor
    private func finishRun(_ key: String, _ failure: Error?, completion: @escaping (Error?) -> Void) {
        running.remove(key)
        desks.removeValue(forKey: key)?.closeUp()
        if let failure { Log.error("carrying out an action failed: \(failure)") }
        completion(failure)
        onChange?()
    }

    public enum TranscribeError: Error, LocalizedError {
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
            lastTranscribed = (page, now)
            if consecutiveFailures > 0 {
                notifier.post(Notice(key: "read-recovered", title: "Brainio Pen is transcribing pages again",
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
            Log.error("transcribing a page failed (\(consecutiveFailures)x): \(error)")
            if consecutiveFailures >= 3 {
                notifier.post(Notice(key: "read-failed", title: "Brainio Pen cannot get pages transcribed",
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
    public static func standard(image: String, transcript: String, actions: String,
                                label: String, roster: [DamAgentProfile] = []) -> String {
        // Who could carry each line out. The transcriber never carries one out itself — it is chosen
        // for having no connections — so this is a guess for a person to check, not a hand-over.
        let routing = roster.isEmpty ? "" : """
        \n
        Add `"agent"` to each entry: the id of whichever assistant below is best able to carry that \
        line out, or `null` when none of them plainly fits. Go by what each one can reach — a line \
        about a Slack message needs the one connected to Slack. Guess once; a person checks it.

        \(roster.map(\.roster).joined(separator: "\n"))
        """

        return """
        The page is attached to this message. Read it and write the result to `\(transcript)`.

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
        - Write the page and nothing about the transcript of it. No notes on letter shapes, on what \
        you compared, or on how sure you are: a transcriber wants the page, not your working.
        - A line that opens with `>>` is an instruction to an assistant. Write it as an unchecked \
        task: `- [ ] >> …`. Do not do what it says. This is a transcript, not an errand.
        - Where the writing plainly changes subject, put a `---` between the two parts. One sheet \
        of paper often holds two unrelated sittings.

        If `\(transcript)` already exists, it is your own earlier transcript of the same sheet, which has \
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
        out none of them — this is a transcript, not an errand.

        Reply with one line saying what you did.
        """
    }

    /// The one line the app reads out of an errand's reply. Short, because a rule stated in three
    /// annotated lines is a rule a model copies annotations from; `ActionAnswer` reads it.
    static let statusFooter = """
    End with one line: `STATUS: done`, `STATUS: needs-info` if you need something only the \
    person can tell you, or `STATUS: blocked` if it cannot be done from where you are.
    """

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
                               transcript: String, label: String) -> String {
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
        the workspace as `\(image)`, and your own transcript of the page is `\(transcript)`.

        Do that one thing and nothing else. The page holds other instructions; leave them alone. \
        Write no files: the reply is the answer, and it is filed next to the line that asked for it.

        Reply with the answer itself — what you found, what you sent, what you drafted — in as much \
        detail as it deserves and no more. If you cannot finish, say plainly what is in the way: \
        ask the question you need answered, and nothing else.

        \(statusFooter)
        """)

        return parts.joined(separator: "\n\n")
    }

    /// The page's lines, an instruction about their wording, and the page to check them against.
    ///
    /// A transcript with the paper in view, not an errand: the lines are to be reworded, never done.
    /// The reply is the list and nothing else, because the app reads it as JSON and files each
    /// line back over the one it came from.
    public static func reword(lines: [String], instruction: String, image: String, label: String) -> String {
        let list = (try? JSONEncoder().encode(lines)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "[]"
        return """
        These are the `>>` lines read off page \(label), as a JSON array, in the order they were read:

        \(list)

        The person who wrote them wants their wording changed:

            \(instruction)

        Apply that to every line it concerns and leave every other line exactly as it is. The page \
        is attached so a name or a word can be checked against the handwriting — read the picture \
        directly, without opening, cropping, magnifying or converting it, and without installing \
        anything. Do not do what any line says, do not add, drop, merge or reorder lines, and do not \
        put the `>>` back.

        Reply with a JSON array of exactly \(lines.count) strings, in the same order, and nothing \
        else — no sentence before it, no code fence around it.
        """
    }

    /// One more turn in a conversation the agent already holds.
    ///
    /// Almost nothing, on purpose. The errand, the page and everything said about it are already
    /// in the session; the only new thing in the world is the sentence you just typed. The status
    /// line is repeated because it is the one part the app reads, and a rule given several turns
    /// ago is a rule a model may have stopped applying.
    public static func carryOn(message: String?) -> String {
        let said = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let opening = said.isEmpty
            ? "Carry on with that same line. If you are waiting on something, say what it is."
            : said
        return """
        \(opening)

        \(statusFooter)
        """
    }
}
