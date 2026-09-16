import Foundation
@testable import BrainioPenCore
import XCTest

/// A page goes to the agent when it has been still for a while and its reading is out of date, and
/// the answer lands beside the strokes it was made from. Nothing here is remembered between ticks:
/// every question is asked of the files.
final class PageProcessorTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brainio-pen-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func stroke(_ page: PageID, start: Int) -> Stroke {
        Stroke(page: page, start: start, end: start + 10,
               dots: [DotSample(x: 10, y: 20, force: 0.5, dt: 0), DotSample(x: 12, y: 21, force: 0.6, dt: 8)],
               source: .live, penMac: "M", firmware: "F")
    }

    /// One page of strokes on disk, in the copy the app would have filed it in.
    private func writePage(_ number: Int = 4, at written: Date? = nil) throws -> (PageRef, BookRegistry) {
        let store = RawStore(root: root, app: "c", sdk: "s")
        let books = BookRegistry(root: root)
        let page = PageID(surface: "s3/o27/b450", page: number)!
        let router = PageRouter(books: books, store: store)
        let group = router.route([stroke(page, start: 1_700_000_000_000)])[0]
        _ = try store.append(group.strokes, to: group.folder)
        let ref = PageRef(folder: group.folder, page: page)
        if let written {
            try FileManager.default.setAttributes([.modificationDate: written],
                                                  ofItemAtPath: books.rawFile(for: ref).path)
        }
        return (ref, books)
    }

    private func processor(_ books: BookRegistry, workspace: FakeWorkspace = FakeWorkspace(),
                           runner: FakeRunner = FakeRunner(), window: TimeInterval = 60)
        -> PageProcessor {
        PageProcessor(books: books, root: root, imaging: FakeImaging(), workspace: workspace,
                      runner: runner, notifier: RecordingNotifier(), quietWindow: window)
    }

    private func processor(_ books: BookRegistry, fleet: FakeFleet,
                           window: TimeInterval = 60) -> PageProcessor {
        PageProcessor(books: books, root: root, imaging: FakeImaging(), fleet: fleet,
                      notifier: RecordingNotifier(), quietWindow: window)
    }

    func testAPageStillBeingWrittenOnIsNotSentYet() throws {
        let (ref, books) = try writePage(at: Date())
        let p = processor(books)
        XCTAssertEqual(p.due(), [])
        // A minute later the hand has moved on.
        XCTAssertEqual(p.due(now: Date().addingTimeInterval(61)), [ref])
    }

    func testAPageWhoseReadingIsUpToDateIsLeftAlone() throws {
        let (ref, books) = try writePage(at: Date().addingTimeInterval(-300))
        let p = processor(books)
        let reading = try XCTUnwrap(p.readingURL(for: ref))
        try FileManager.default.createDirectory(at: reading.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "# already read".write(to: reading, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-200)],
                                              ofItemAtPath: reading.path)
        XCTAssertEqual(p.due(), [])

        // Written on again: the captured file is now the newer of the two, so it goes again.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-100)],
                                              ofItemAtPath: books.rawFile(for: ref).path)
        XCTAssertEqual(p.due(), [ref])
    }

    func testAPageStillWarmCanBeSentAtOnceWhenSomebodyAsks() throws {
        let (ref, books) = try writePage(at: Date())
        let p = processor(books)
        // The minute has not passed, so nothing goes on its own.
        XCTAssertEqual(p.due(), [])
        // The panel still offers it: the person can see it is there and has decided not to wait.
        XCTAssertEqual(p.outstanding, [ref])
    }

    func testAskingToReadNowWorksThroughEveryPageThatIsWaiting() async throws {
        let (first, books) = try writePage(4, at: Date())
        let (second, _) = try writePage(5, at: Date())
        let workspace = FakeWorkspace()
        // The agent writes a reading for each page; the fake stands in for that.
        workspace.files["work/pen/\(first.folder.name)/p4.md"] = Data("# p4".utf8)
        workspace.files["work/pen/\(second.folder.name)/p5.md"] = Data("# p5".utf8)
        let p = processor(books, workspace: workspace)
        // Both were written a moment ago, so neither would go on its own yet.
        XCTAssertEqual(p.due(), [])
        XCTAssertEqual(Set(p.outstanding), [first, second])

        // The panel says "Read 2 pages now", and that is what it has to mean.
        p.readNow()
        XCTAssertTrue(p.sweeping)
        try await p.read(first)
        try await p.read(second)
        XCTAssertEqual(Set(p.outstanding), [])

        // Nothing left: the next tick ends the sweep rather than looking again forever.
        p.tick()
        XCTAssertFalse(p.sweeping)
    }

    func testAFailureEndsTheSweepRatherThanRepeatingItPerPage() async throws {
        let (ref, books) = try writePage(4, at: Date())
        _ = try writePage(5, at: Date())
        let runner = FakeRunner()
        runner.failure = DamRunError.connection("no route")
        let p = processor(books, runner: runner)
        p.readNow()
        XCTAssertTrue(p.sweeping)

        // The attempt the click started fails; the backoff takes over and the pages still owed a
        // reading wait their turn rather than failing one after another.
        let deadline = Date().addingTimeInterval(3)
        while p.sweeping, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(p.sweeping)
        XCTAssertEqual(p.consecutiveFailures, 1)
        XCTAssertNotNil(p.nextRetryAt)
        // Nothing was written, so both pages are still owed.
        XCTAssertTrue(p.outstanding.contains(ref))
    }

    func testTapsOnAControlSurfaceAreNeverRead() throws {
        let (ref, books) = try writePage(at: Date().addingTimeInterval(-300))
        let p = processor(books)
        p.controlBooks = [ref.folder.surface]
        XCTAssertEqual(p.due(), [])
    }

    func testTheRoundTripPutsTheImageUpAndTheReadingBack() async throws {
        let (ref, books) = try writePage(at: Date().addingTimeInterval(-300))
        let workspace = FakeWorkspace()
        workspace.files["work/pen/\(ref.folder.name)/p4.md"] = Data("# p4\n\n- [ ] >> book the room".utf8)
        let runner = FakeRunner()
        let p = processor(books, workspace: workspace, runner: runner)

        try await p.read(ref)

        // Uploaded under `work/`, because the file API is rooted at the agent's home while the
        // agent itself runs one directory down.
        XCTAssertEqual(workspace.uploaded.map(\.path), ["work/pen/\(ref.folder.name)/p4.png"])
        XCTAssertEqual(workspace.uploaded.first?.contentType, "image/png")
        // The page travels with the prompt, so the reader is shown it rather than sent to fetch it.
        XCTAssertEqual(runner.images.first?.mimeType, "image/png")
        XCTAssertEqual(runner.images.first?.data, Data([0x89, 0x50, 0x4E, 0x47]))
        // The prompt names both files as the agent sees them: no `work/`, or it looks in
        // `~/work/work/pen` and finds nothing.
        let prompt = try XCTUnwrap(runner.prompts.first)
        XCTAssertTrue(prompt.contains("`pen/\(ref.folder.name)/p4.png`"))
        XCTAssertTrue(prompt.contains("`pen/\(ref.folder.name)/p4.md`"))
        XCTAssertFalse(prompt.contains("work/pen/"))

        let reading = try XCTUnwrap(p.readingURL(for: ref))
        XCTAssertEqual(try String(contentsOf: reading, encoding: .utf8), "# p4\n\n- [ ] >> book the room")
        XCTAssertEqual(reading.lastPathComponent, "p4.md")
        // Beside the captured file it was made from, never inside raw/.
        XCTAssertEqual(reading.deletingLastPathComponent().lastPathComponent, "pages")
    }

    func testAnEarlierReadingGoesUpWithTheImage() async throws {
        let (ref, books) = try writePage(at: Date().addingTimeInterval(-300))
        let workspace = FakeWorkspace()
        let p = processor(books, workspace: workspace)
        let reading = try XCTUnwrap(p.readingURL(for: ref))
        try FileManager.default.createDirectory(at: reading.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "- [x] >> already done".write(to: reading, atomically: true, encoding: .utf8)
        workspace.files["work/pen/\(ref.folder.name)/p4.md"] = Data("- [x] >> already done".utf8)

        try await p.read(ref)

        XCTAssertEqual(workspace.uploaded.map(\.path).sorted(),
                       ["work/pen/\(ref.folder.name)/p4.md", "work/pen/\(ref.folder.name)/p4.png"])
    }

    func testAFailedRunBacksOffAndTheStrokesStayPut() async throws {
        let (ref, books) = try writePage(at: Date().addingTimeInterval(-300))
        let runner = FakeRunner()
        runner.failure = DamRunError.stalled("Bash(rm)")
        let p = processor(books, runner: runner)

        do {
            try await p.read(ref)
            XCTFail("a stalled run is not a reading")
        } catch {
            XCTAssertEqual(error as? DamRunError, .stalled("Bash(rm)"))
        }
        // Nothing was written, so the page is still owed a reading.
        XCTAssertEqual(p.due(), [ref])
    }
}

extension PageProcessorTests {
    /// Carrying one line out: the answer is the reply, and it is filed beside the line that asked.

    private func executed(_ p: PageProcessor, _ action: PageAction, on ref: PageRef,
                          say: String? = nil) async -> Error? {
        await withCheckedContinuation { continuation in
            p.execute(action: action, on: ref, say: say) { continuation.resume(returning: $0) }
        }
    }

    private func reworded(_ p: PageProcessor, _ ref: PageRef, _ instruction: String) async -> Error? {
        await withCheckedContinuation { continuation in
            p.reword(ref, instruction: instruction) { continuation.resume(returning: $0) }
        }
    }

    func testTheReaderCanBeAskedToFixTheWording() async throws {
        let (ref, books) = try writePage()
        let runner = FakeRunner()
        runner.reply = """
        Here you go:
        ["Find out who is Ondřej Široký from Apoco", "Send the pricing to Brainio"]
        """
        let p = processor(books, runner: runner)
        let url = try XCTUnwrap(p.actionsURL(for: ref))
        let said = [ActionMessage(from: .agent, text: "Which pricing?")]
        try PageActions.save([PageAction(text: "FIND OUT WHO IS ONDREJ SIROKY FROM APOCO"),
                              PageAction(text: "Send the pricing to Brainio", thread: said, session: "s-1",
                                         agent: "mailer")], to: url)

        let failure = await reworded(p, ref, "fix the name and the case")
        XCTAssertNil(failure)
        let after = PageActions.load(url)
        XCTAssertEqual(after.map(\.text), ["Find out who is Ondřej Široký from Apoco", "Send the pricing to Brainio"])
        // The fixed line remembers the paper's words; the untouched one has nothing to remember.
        XCTAssertEqual(after[0].paper, "FIND OUT WHO IS ONDREJ SIROKY FROM APOCO")
        XCTAssertNil(after[1].paper)
        XCTAssertEqual(after[1].thread.map(\.text), ["Which pricing?"])
        XCTAssertEqual(after[1].session, "s-1")
        XCTAssertEqual(after[1].agent, "mailer")
        // The reader was asked, with the page in view, and told what to change.
        XCTAssertEqual(runner.images.count, 1)
        XCTAssertTrue(runner.prompts[0].contains("fix the name and the case"))
        XCTAssertTrue(runner.prompts[0].contains("FIND OUT WHO IS ONDREJ SIROKY FROM APOCO"))
    }

    func testAReplyThatIsNotTheLinesChangesNothing() async throws {
        let (ref, books) = try writePage()
        let runner = FakeRunner()
        runner.reply = "I lowercased them for you."
        let p = processor(books, runner: runner)
        let url = try XCTUnwrap(p.actionsURL(for: ref))
        try PageActions.save([PageAction(text: "CALL THE LANDLORD")], to: url)

        let failure = await reworded(p, ref, "lowercase")
        XCTAssertNotNil(failure)
        XCTAssertEqual(PageActions.load(url).map(\.text), ["CALL THE LANDLORD"])

        runner.reply = "[\"call the landlord\", \"and another\"]"
        let wrongCount = await reworded(p, ref, "lowercase")
        XCTAssertNotNil(wrongCount)
        XCTAssertEqual(PageActions.load(url).map(\.text), ["CALL THE LANDLORD"])
    }

    func testAnAnswerIsFiledBesideTheLineThatAskedForIt() async throws {
        let (ref, books) = try writePage()
        let runner = FakeRunner()
        runner.reply = "Ondrej Siroky runs delivery at Apoco.\n\nSTATUS: done"
        let p = processor(books, runner: runner)
        let url = try XCTUnwrap(p.actionsURL(for: ref))
        let action = PageAction(text: "FIND OUT WHO IS ONDREJ SIROKY")
        try PageActions.save([action], to: url)

        let failure = await executed(p, action, on: ref)
        XCTAssertNil(failure)
        let after = try XCTUnwrap(PageActions.load(url).first)
        XCTAssertTrue(after.done)
        XCTAssertEqual(after.thread.map(\.from), [.agent])
        XCTAssertEqual(after.thread[0].text, "Ondrej Siroky runs delivery at Apoco.")
        XCTAssertEqual(after.session, "sess-1")
        // The status line is the app's, not the reader's: it never appears in what is shown.
        XCTAssertFalse(after.note!.contains("STATUS"))
    }

    func testAQuestionLeavesTheActionOpenAndWaitingOnYou() async throws {
        let (ref, books) = try writePage()
        let runner = FakeRunner()
        runner.reply = "Which Tomas?\nSTATUS: needs-info"
        let p = processor(books, runner: runner)
        let url = try XCTUnwrap(p.actionsURL(for: ref))
        let action = PageAction(text: "SEND THIS TO TOMAS")
        try PageActions.save([action], to: url)

        let failure = await executed(p, action, on: ref)
        XCTAssertNil(failure)
        var after = try XCTUnwrap(PageActions.load(url).first)
        XCTAssertFalse(after.done)
        XCTAssertTrue(after.needsYou)

        // Answering says the new thing and nothing else: the agent is carrying on a conversation
        // it still holds, and repeating the errand would have it read its own words twice.
        runner.reply = "Sent to Tomas Novak.\nSTATUS: done"
        let second = await executed(p, after, on: ref, say: "Tomas Novak")
        XCTAssertNil(second)
        after = try XCTUnwrap(PageActions.load(url).first)
        XCTAssertEqual(after.thread.map(\.from), [.agent, .you, .agent])
        XCTAssertTrue(after.done)
        XCTAssertFalse(after.needsYou)
        XCTAssertTrue(runner.prompts.last!.contains("Tomas Novak"))
        XCTAssertFalse(runner.prompts.last!.contains("Which Tomas?"))
        XCTAssertFalse(runner.prompts.last!.contains("SEND THIS TO TOMAS"))
        // The status line goes with it, because it is the one part the app reads.
        XCTAssertTrue(runner.prompts.last!.contains("STATUS: done"))
        // And the page is not sent a second time: the agent already has it.
        XCTAssertEqual(runner.images.count, 1)
        // It is the same session on the far side, so the agent still has what it found.
        XCTAssertEqual(runner.resumed, [nil, "sess-1"])
    }

    /// A pod restarted under us, so `session/load` failed and a new session started. The agent on
    /// the other side has never seen any of this, and one bare sentence would be a pronoun handed
    /// to a stranger.
    func testALostSessionIsToldTheWholeErrandAgain() async throws {
        let (ref, books) = try writePage()
        let runner = FakeRunner()
        runner.reply = "Which Tomas?\nSTATUS: needs-info"
        let p = processor(books, runner: runner)
        let url = try XCTUnwrap(p.actionsURL(for: ref))
        let action = PageAction(text: "SEND THIS TO TOMAS")
        try PageActions.save([action], to: url)

        _ = await executed(p, action, on: ref)
        let after = try XCTUnwrap(PageActions.load(url).first)

        runner.sessionSurvives = false
        runner.reply = "Sent to Tomas Novak.\nSTATUS: done"
        _ = await executed(p, after, on: ref, say: "Tomas Novak")

        let last = try XCTUnwrap(runner.prompts.last)
        XCTAssertTrue(last.contains("SEND THIS TO TOMAS"))
        XCTAssertTrue(last.contains("Which Tomas?"))
        XCTAssertTrue(last.contains("Tomas Novak"))
        // And the page goes with it, because this agent has not been shown it.
        XCTAssertEqual(runner.images.count, 2)
    }

    /// A turn cut off at its token limit says so. "Said nothing" reads as a broken app, and sends
    /// somebody looking in the wrong place — the limit is a setting on the far side.
    func testATurnCutOffAtItsLimitSaysSo() {
        XCTAssertTrue(PageProcessor.nothingSaid("max_tokens").contains("token limit"))
        XCTAssertTrue(PageProcessor.nothingSaid("end_turn").contains("without saying anything"))
        XCTAssertTrue(PageProcessor.nothingSaid(nil).contains("without saying anything"))
    }

    func testAnAnswerWithNoStatusNeverTicksTheBox() async throws {
        let (ref, books) = try writePage()
        let runner = FakeRunner()
        runner.reply = "I think I have done it."
        let p = processor(books, runner: runner)
        let url = try XCTUnwrap(p.actionsURL(for: ref))
        let action = PageAction(text: "CALL")
        try PageActions.save([action], to: url)

        let failure = await executed(p, action, on: ref)
        XCTAssertNil(failure)
        let after = try XCTUnwrap(PageActions.load(url).first)
        XCTAssertFalse(after.done)
        XCTAssertEqual(after.note, "I think I have done it.")
    }

    func testWhatYouTypedSurvivesATurnThatFails() async throws {
        let (ref, books) = try writePage()
        let runner = FakeRunner()
        runner.failure = DamRunError.connection("socket closed")
        let p = processor(books, runner: runner)
        let url = try XCTUnwrap(p.actionsURL(for: ref))
        let action = PageAction(text: "CALL")
        try PageActions.save([action], to: url)

        let broke = await executed(p, action, on: ref, say: "the landlord, not the agency")
        XCTAssertNotNil(broke)
        let after = try XCTUnwrap(PageActions.load(url).first)
        XCTAssertEqual(after.thread.map(\.text), ["the landlord, not the agency"])
        XCTAssertFalse(after.done)
    }

    /// The whole point of a roster: the agent that looks at the paper has no connections, and the
    /// agent with the connections is only ever given a line a person has seen routed to it.
    func testALineGoesToTheAgentItIsRoutedTo() async throws {
        let (ref, books) = try writePage()
        let fleet = FakeFleet()
        fleet.reply = "Posted it.\nSTATUS: done"
        let p = processor(books, fleet: fleet)
        let url = try XCTUnwrap(p.actionsURL(for: ref))
        let action = PageAction(text: "SEND TO BRAINIO", agent: "agent-slack")
        try PageActions.save([action], to: url)

        let failure = await executed(p, action, on: ref)
        XCTAssertNil(failure)
        XCTAssertEqual(fleet.prompted, ["agent-slack"])
        // And the page goes to that agent's own workspace, not the reader's: it cannot read what
        // it was never given.
        XCTAssertEqual(fleet.staged, ["agent-slack"])
    }

    func testAnUnroutedLineStaysWithTheReader() async throws {
        let (ref, books) = try writePage()
        let fleet = FakeFleet()
        let p = processor(books, fleet: fleet)
        let url = try XCTUnwrap(p.actionsURL(for: ref))
        let action = PageAction(text: "CALL")
        try PageActions.save([action], to: url)

        _ = await executed(p, action, on: ref)
        XCTAssertEqual(fleet.prompted, [nil])
    }

    func testTheReaderIsToldWhoCouldCarryEachLineOut() async throws {
        let (ref, books) = try writePage(at: Date().addingTimeInterval(-300))
        let runner = FakeRunner()
        let workspace = FakeWorkspace()
        let p = processor(books, workspace: workspace, runner: runner)
        p.roster = [DamAgentProfile(id: "agent-slack", name: "Ops", summary: "Runs the rota.",
                                    systems: ["Slack"])]
        workspace.files[p.workspacePath(for: ref, ext: "md")] = Data("# page".utf8)

        try await p.read(ref)
        let prompt = try XCTUnwrap(runner.prompts.first)
        XCTAssertTrue(prompt.contains("agent-slack"))
        XCTAssertTrue(prompt.contains("Can reach: Slack."))
        XCTAssertTrue(prompt.contains("\"agent\""))
    }

    func testWithNoRosterTheReaderIsNotAskedToRouteAnything() async throws {
        let (ref, books) = try writePage(at: Date().addingTimeInterval(-300))
        let runner = FakeRunner()
        let workspace = FakeWorkspace()
        let p = processor(books, workspace: workspace, runner: runner)
        workspace.files[p.workspacePath(for: ref, ext: "md")] = Data("# page".utf8)

        try await p.read(ref)
        XCTAssertFalse(try XCTUnwrap(runner.prompts.first).contains("\"agent\""))
    }

    func testWhereALineWasRoutedSurvivesTheNextReading() {
        // A person changed it, or the first reading chose it. Either way the paper has no say.
        let ours = [PageAction(text: "SEND TO BRAINIO", agent: "agent-slack")]
        let merged = PageActions.merge(ours: ours,
                                       theirs: [PageAction(text: "send to brainio", agent: "agent-other")])
        XCTAssertEqual(merged.map(\.agent), ["agent-slack"])
    }

    func testAReadingOfThePageCannotLoseTheConversation() async throws {
        // The two paths write the same file. A reading proposes what the paper says; it has never
        // heard of the exchange, and must not take it away.
        let (ref, books) = try writePage()
        let p = processor(books)
        let url = try XCTUnwrap(p.actionsURL(for: ref))
        try PageActions.save([PageAction(text: "CALL", done: true,
                                         thread: [ActionMessage(from: .agent, text: "Called.")],
                                         session: "sess-9")], to: url)
        let merged = PageActions.merge(ours: PageActions.load(url), theirs: [PageAction(text: "call")])
        XCTAssertEqual(merged[0].thread.map(\.text), ["Called."])
        XCTAssertEqual(merged[0].session, "sess-9")
        XCTAssertTrue(merged[0].done)
    }
}

/// A fleet that answers for anybody and remembers who was asked.
private final class FakeFleet: DamFleet, @unchecked Sendable {
    private let lock = NSLock()
    let runner = FakeRunner()
    private let space = FakeWorkspace()
    /// Stands in for DAM's approvals queue, which is where an egress hold is answered.
    let gate = FakeApprovals()
    var prompted: [String?] = []
    var staged: [String?] = []
    var reply: String {
        get { runner.reply }
        set { runner.reply = newValue }
    }

    func prompter(for agentId: String?) throws -> DamPrompting {
        lock.withLock { prompted.append(agentId) }
        return runner
    }

    func workspace(for agentId: String?) throws -> DamWorkspace {
        // The reader's own reads and writes pass nil; anything else is a hand-over.
        if let agentId { lock.withLock { staged.append(agentId) } }
        return space
    }

    func approvals(for agentId: String?) throws -> DamApprovals? { gate }
}

final class FakeApprovals: DamApprovals, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [(String, ApprovalVerdict)] = []
    var decided: [(String, ApprovalVerdict)] { lock.withLock { answers } }

    func decide(approvalId: String, verdict: ApprovalVerdict) async throws {
        lock.withLock { answers.append((approvalId, verdict)) }
    }
}

private final class FakeImaging: PageImaging {
    func png(for ref: PageRef) -> Data? { Data([0x89, 0x50, 0x4E, 0x47]) }
}

private final class FakeWorkspace: DamWorkspace, @unchecked Sendable {
    private let lock = NSLock()
    var files: [String: Data] = [:]
    var uploaded: [(path: String, contentType: String)] = []

    func upload(path: String, data: Data, contentType: String, overwrite: Bool) async throws {
        lock.withLock {
            uploaded.append((path, contentType))
            files[path] = data
        }
    }

    func read(path: String) async throws -> DamFile {
        guard let data = lock.withLock({ files[path] }) else { throw DamError.notFound(path: path) }
        return DamFile(path: path, data: data, mimeType: "text/markdown", mtimeMs: 1)
    }
}

private final class FakeRunner: DamPrompting, @unchecked Sendable {
    private let lock = NSLock()
    var prompts: [String] = []
    var images: [DamImage] = []
    var failure: Error?
    /// What the agent says back. The default is a reading; an execution test sets its own.
    var reply = "read it"

    /// The sessions it was asked to carry on, so a test can say whether the conversation stayed
    /// in one.
    var resumed: [String?] = []

    /// A question the agent is stopped by the moment the prompt lands, as DAM's gate would put it.
    /// The turn then waits for it to be answered, which is the behaviour being tested.
    var heldUpBy: ApprovalAsk?

    /// Whether the agent still holds the session it is asked to carry on. True unless a test says
    /// otherwise, which is the case worth asserting: a pod restarted under us.
    var sessionSurvives = true

    func run(turn: @Sendable @escaping (_ resumed: Bool) -> DamTurn, resume: String?,
             timeout: TimeInterval, approvals: ApprovalDesk?) async throws -> DamRunResult {
        let carriedOn = resume != nil && lock.withLock { sessionSurvives }
        let what = turn(carriedOn)
        lock.withLock {
            prompts.append(what.prompt)
            resumed.append(resume)
            if let image = what.image { images.append(image) }
        }
        if let ask = lock.withLock({ heldUpBy }), let approvals {
            approvals.post(ask)
            while approvals.isWaiting { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        if let failure { throw failure }
        return DamRunResult(sessionId: "sess-1", text: reply, stopReason: "end_turn")
    }
}

extension PageProcessorTests {
    /// Two lines at once. They are often two different agents, and even on one agent DAM queues
    /// them — which is a better place for a queue than here, where it looks like the app stopped.
    func testTwoLinesCanBeCarriedOutAtTheSameTime() async throws {
        let (ref, books) = try writePage()
        let fleet = FakeFleet()
        let p = processor(books, fleet: fleet)
        let url = try XCTUnwrap(p.actionsURL(for: ref))
        let first = PageAction(text: "CALL")
        let second = PageAction(text: "SEND IT")
        try PageActions.save([first, second], to: url)

        async let a: Error? = executed(p, first, on: ref)
        async let b: Error? = executed(p, second, on: ref)
        let (one, two) = await (a, b)
        XCTAssertNil(one)
        XCTAssertNil(two)
        // Both answers survive: the file is written under a lock, so neither reply is lost.
        let after = PageActions.load(url)
        XCTAssertEqual(after.count, 2)
        XCTAssertTrue(after.allSatisfy { !$0.thread.isEmpty })
    }

    /// The whole loop: the agent is stopped at DAM's gate, the line says so, a person allows it,
    /// the answer goes to the queue the gate is waiting on, and the turn finishes.
    func testALineHeldAtTheGateWaitsForYouAndThenCarriesOn() async throws {
        let (ref, books) = try writePage()
        let fleet = FakeFleet()
        fleet.runner.heldUpBy = ApprovalAsk(id: "hold-1",
                                            kind: .egress(method: "POST", host: "slack.com",
                                                          path: "/api/chat.postMessage"),
                                            approvalId: "hold-1")
        let p = processor(books, fleet: fleet)
        let url = try XCTUnwrap(p.actionsURL(for: ref))
        let action = PageAction(text: "TELL TOMAS")
        try PageActions.save([action], to: url)

        async let finished: Error? = executed(p, action, on: ref)

        var ask: ApprovalAsk?
        for _ in 0..<500 where ask == nil {
            ask = p.waiting(on: action.key).first
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let held = try XCTUnwrap(ask, "the line should say what it is waiting for")
        XCTAssertEqual(held.title, "POST slack.com")

        try await p.decide(held, on: action.key, .allowOnce)
        XCTAssertEqual(fleet.gate.decided.map(\.0), ["hold-1"])
        XCTAssertEqual(fleet.gate.decided.map(\.1), [.allowOnce])

        let outcome = await finished
        XCTAssertNil(outcome)
        // The question dies with the turn: nothing is left on the row to answer twice.
        XCTAssertTrue(p.waiting(on: action.key).isEmpty)
        XCTAssertFalse(PageActions.load(url)[0].thread.isEmpty)
    }

    func testTheSameLineTwiceIsRefused() async throws {
        let (ref, books) = try writePage()
        let fleet = FakeFleet()
        let p = processor(books, fleet: fleet)
        let url = try XCTUnwrap(p.actionsURL(for: ref))
        let action = PageAction(text: "CALL")
        try PageActions.save([action], to: url)

        // One in the air, and the same one asked for again while it is.
        let second: Error? = await withCheckedContinuation { continuation in
            p.execute(action: action, on: ref, say: nil) { _ in }
            p.execute(action: action, on: ref, say: nil) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(second is PageProcessor.ExecuteError)
    }
}
