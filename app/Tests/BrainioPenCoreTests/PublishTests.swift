import Foundation
@testable import BrainioPenCore
import XCTest

/// Runs real `git` against a temporary repository (no remote, push disabled).
///
/// Git is a record of what changed, not where the notes live: the files are read from
/// `~/Brainio/pen` and a commit only says which of them moved (ADR-002).
final class PublishTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brainio-pen-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Each stroke gets its own geometry, derived from `start`, so distinct strokes never look
    /// like duplicates of one another (see RawStore's duplicate rejection).
    func stroke(_ page: PageID, start: Int) -> Stroke {
        let x = Double(start % 1000)
        return Stroke(page: page, start: start, end: start + 10,
               dots: [DotSample(x: x, y: 2, force: 0.3, dt: 0), DotSample(x: x + 0.5, y: 2.5, force: 0.4, dt: 12)],
               source: .live, penMac: "M", firmware: "F")
    }

    func makePublisher() throws -> GitPublisher {
        let p = GitPublisher(repo: root, push: false)
        let hasRemote = try p.ensureRepository()
        XCTAssertFalse(hasRemote)
        // Identity so commits work on a machine without global git config.
        _ = try p.run(["config", "user.email", "test@example.com"])
        _ = try p.run(["config", "user.name", "test"])
        return p
    }

    /// The whole capture flow, wired as the app wires it.
    func makeFlow(publisher: Publishing, quietWindow: TimeInterval = 600,
                  notifier: Notifier = RecordingNotifier())
        -> (coordinator: SyncCoordinator, books: BookRegistry, store: RawStore) {
        let store = RawStore(root: root, app: "c", sdk: "s")
        let books = BookRegistry(root: root)
        let c = SyncCoordinator(store: store, router: PageRouter(books: books, store: store),
                                tracker: QuietTracker(), publisher: publisher, notifier: notifier,
                                quietWindow: quietWindow)
        return (c, books, store)
    }

    /// The copy a page is in right now. Folder ids are generated, so a test asks rather than spells.
    func ref(_ page: PageID, _ books: BookRegistry) throws -> PageRef {
        PageRef(folder: try XCTUnwrap(books.current(for: page.surface)).folder, page: page)
    }

    func testEnsureRepositoryIsIdempotent() throws {
        let p = try makePublisher()
        XCTAssertFalse(try p.ensureRepository())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
    }

    func testPublishCommitsOnlyGivenPathsAndSkipsWhenClean() throws {
        let p = try makePublisher()
        let flow = makeFlow(publisher: p)
        let a = PageID(section: 3, owner: 27, book: 5, page: 1)
        let b = PageID(section: 3, owner: 27, book: 5, page: 2)
        flow.coordinator.ingestLive([stroke(a, start: 1), stroke(b, start: 1)])
        let refA = try ref(a, flow.books), refB = try ref(b, flow.books)

        let hash = try p.publish(paths: [refA.rawRelativePath], message: "one page")
        XCTAssertNotNil(hash)
        let tracked = try p.run(["ls-files"]).output
        XCTAssertTrue(tracked.contains(refA.rawRelativePath))
        XCTAssertFalse(tracked.contains(refB.rawRelativePath), "page b was not staged")

        XCTAssertNil(try p.publish(paths: [refA.rawRelativePath], message: "again"), "nothing new to commit")
        XCTAssertNotNil(try p.publish(paths: [refB.rawRelativePath], message: "second page"))
        let count = try p.run(["rev-list", "--count", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(count, "2")
    }

    func testCoordinatorPublishesQuietPagesAndKeepsBusyOnes() throws {
        let p = try makePublisher()
        let rec = RecordingNotifier()
        let flow = makeFlow(publisher: p, notifier: rec)
        let c = flow.coordinator
        let a = PageID(section: 3, owner: 27, book: 5, page: 1)
        let b = PageID(section: 3, owner: 27, book: 5, page: 2)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        c.ingestLive([stroke(a, start: 1)], now: t0)
        c.ingestLive([stroke(b, start: 1)], now: t0.addingTimeInterval(500))
        XCTAssertEqual(Set(c.pendingPages), [try ref(a, flow.books), try ref(b, flow.books)])

        let done = expectation(description: "published")
        c.onChange = { done.fulfill() }
        c.tick(now: t0.addingTimeInterval(650))
        wait(for: [done], timeout: 30)

        XCTAssertEqual(c.pendingPages, [try ref(b, flow.books)], "b is still within the quiet window")
        XCTAssertEqual(c.lastPublish?.pages, 1)
        XCTAssertNotNil(c.lastPublish?.commit)
        XCTAssertTrue(rec.notices.isEmpty)
    }

    func testOfflineStrokesPublishImmediately() throws {
        let p = try makePublisher()
        let flow = makeFlow(publisher: p)
        let c = flow.coordinator
        let a = PageID(section: 3, owner: 27, book: 5, page: 1)
        var offline = stroke(a, start: 1)
        offline.source = .offline
        let pages = c.ingestOffline([offline])
        XCTAssertEqual(pages, [try ref(a, flow.books)])
        XCTAssertEqual(c.tracker.quietPages(now: Date(), window: 600), [try ref(a, flow.books)])

        let done = expectation(description: "published")
        c.publish(pages: Array(pages), reason: "drain") { result in
            if case .failure(let e) = result { XCTFail("\(e)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        XCTAssertTrue(c.pendingPages.isEmpty)
    }

    func testPublishFailureNotifiesAfterThreeAttempts() throws {
        final class Failing: Publishing {
            var push = false
            func publish(paths: [String], message: String) throws -> String? {
                throw PublishError.git(command: "push", status: 1, output: "no network")
            }
            func dirtyPaths(under prefixes: [String]) -> [String] { [] }
        }
        let rec = RecordingNotifier()
        let flow = makeFlow(publisher: Failing(), quietWindow: 0, notifier: rec)
        let c = flow.coordinator
        let a = PageID(section: 3, owner: 27, book: 5, page: 1)
        c.ingestLive([stroke(a, start: 1)])
        var now = Date()
        for i in 1...3 {
            let done = expectation(description: "attempt \(i)")
            c.onChange = { done.fulfill() }
            c.tick(now: now)
            wait(for: [done], timeout: 5)
            now = now.addingTimeInterval(60 * 60) // past any backoff
        }
        XCTAssertEqual(c.consecutiveFailures, 3)
        XCTAssertEqual(rec.notices.map(\.key), ["publish-failed"])
        XCTAssertEqual(c.pendingPages, [try ref(a, flow.books)], "data stays pending")
    }

    func testRecoverPendingAdoptsUncommittedCapturedFiles() throws {
        let p = try makePublisher()
        let flow = makeFlow(publisher: p)
        let a = PageID(section: 3, owner: 27, book: 5, page: 1)
        let b = PageID(section: 3, owner: 27, book: 450, page: 12)
        flow.coordinator.ingestLive([stroke(a, start: 1), stroke(b, start: 1)])
        let refA = try ref(a, flow.books), refB = try ref(b, flow.books)
        XCTAssertNotNil(try p.publish(paths: [refA.rawRelativePath], message: "a"))
        flow.coordinator.ingestLive([stroke(a, start: 987)]) // a modified after commit, b never committed

        let fresh = makeFlow(publisher: p).coordinator
        XCTAssertTrue(fresh.pendingPages.isEmpty)
        let recovered = fresh.recoverPending()
        XCTAssertEqual(Set(recovered), [refA, refB])
        XCTAssertEqual(Set(fresh.pendingPages), [refA, refB])
        // Dated by mtime (just now), so not yet quiet…
        XCTAssertTrue(fresh.tracker.quietPages(now: Date(), window: 600).isEmpty)
        // …but quiet once the window passes.
        XCTAssertEqual(Set(fresh.tracker.quietPages(now: Date().addingTimeInterval(601), window: 600)), [refA, refB])
    }

    /// Readable files are made again from the record, so committing them would bury the strokes
    /// that actually changed under a wall of regenerated SVG.
    func testReadableFilesAreNotCommittedWithTheCapture() throws {
        let p = try makePublisher()
        let flow = makeFlow(publisher: p)
        let a = PageID(section: 3, owner: 27, book: 5, page: 1)
        flow.coordinator.ingestLive([stroke(a, start: 1)])
        let folder = try ref(a, flow.books).folder
        let pages = root.appendingPathComponent("\(folder.relativePath)/pages")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try Data("<svg/>".utf8).write(to: pages.appendingPathComponent("p1.svg"))

        let done = expectation(description: "published")
        flow.coordinator.publishAll { _ in done.fulfill() }
        wait(for: [done], timeout: 30)
        let tracked = try p.run(["ls-files"]).output
        XCTAssertTrue(tracked.contains("raw/p1.jsonl"))
        XCTAssertFalse(tracked.contains("p1.svg"))
    }

    func testControlSurfaceTapsAreNotFiledAsNotes() throws {
        let p = try makePublisher()
        let flow = makeFlow(publisher: p)
        let c = flow.coordinator
        c.controlBooks = ["s3/o1013/b1"]
        var taps: [Stroke] = []
        c.onControlTap = { taps.append($0) }

        let note = PageID(section: 3, owner: 1012, book: 3017, page: 4)
        let control = PageID(section: 3, owner: 1013, book: 1, page: 11)
        c.ingestLive([stroke(note, start: 1), stroke(control, start: 2)])

        XCTAssertEqual(c.pendingPages, [try ref(note, flow.books)], "the tap is a command, not a page")
        XCTAssertEqual(taps.count, 1)
        XCTAssertEqual(taps.first?.page, control)
        // The tap is stored: the pen saw it, so the record says so, and the mode event points back
        // at it. What makes it "not a page" is that it never enters the tracker, asserted above.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: flow.store.fileURL(for: try ref(control, flow.books)).path))

        // Same for strokes drained from pen memory.
        var offlineTap = stroke(control, start: 3); offlineTap.source = .offline
        XCTAssertTrue(c.ingestOffline([offlineTap]).isEmpty)
        XCTAssertEqual(taps.count, 2)
    }

    func testSurfaceIdentityIsTheAddressWithoutThePage() {
        XCTAssertEqual(PageID(section: 3, owner: 1013, book: 1, page: 11).surface, "s3/o1013/b1")
    }
}
