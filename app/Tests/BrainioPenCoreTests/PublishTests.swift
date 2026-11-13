import Foundation
@testable import BrainioPenCore
import XCTest

/// Stands where the network is: keeps what was put, by path, and can be told to refuse.
final class FakeBucket: S3Transport {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]
    private var log: [URLRequest] = []
    /// When set, every request gets this instead of being kept.
    var refusal: (status: Int, body: String)?
    var offline = false

    var objects: [String: Data] { lock.lock(); defer { lock.unlock() }; return stored }
    /// Put something in the bucket the way the other side would.
    func place(_ data: Data, at path: String) { lock.lock(); stored[path] = data; lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return log }
    var paths: [String] { requests.compactMap { $0.url?.path } }

    func send(_ request: URLRequest, body: Data) -> Result<(status: Int, body: Data), Error> {
        lock.lock(); defer { lock.unlock() }
        log.append(request)
        if offline { return .failure(URLError(.notConnectedToInternet)) }
        if let refusal { return .success((refusal.status, Data(refusal.body.utf8))) }
        let path = request.url?.path ?? ""
        if request.httpMethod == "GET" {
            guard let found = stored[path] else {
                return .success((404, Data("<Error><Code>NoSuchKey</Code></Error>".utf8)))
            }
            return .success((200, found))
        }
        stored[path] = body
        return .success((200, Data()))
    }
}

/// The whole capture flow against a bucket that is a dictionary.
///
/// The notes live in the folder; the bucket is a copy of the record, made as pages go quiet.
final class PublishTests: XCTestCase {
    var root: URL!
    var bucket: FakeBucket!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brainio-pen-s3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        bucket = FakeBucket()
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

    var ledger: URL { root.appendingPathComponent("config/s3-uploaded.json") }
    var notes: URL { root.appendingPathComponent("notes") }

    func account(bucket name: String = "notes", prefix: String = "pen") throws -> S3Account {
        var settings = S3Settings()
        settings.bucket = name
        settings.prefix = prefix
        settings.accessKeyId = "AKIAEXAMPLE"
        return try XCTUnwrap(S3Account(settings: settings, secret: "secret"))
    }

    func makeSync(connected: Bool = true) throws -> S3Sync {
        let sync = S3Sync(root: notes, ledger: ledger)
        if connected { sync.connect(S3Client(account: try account(), transport: bucket)) }
        return sync
    }

    /// The whole capture flow, wired as the app wires it.
    func makeFlow(publisher: Publishing, quietWindow: TimeInterval = 600,
                  notifier: Notifier = RecordingNotifier())
        -> (coordinator: SyncCoordinator, books: BookRegistry, store: RawStore) {
        let store = RawStore(root: notes, app: "c", sdk: "s")
        let books = BookRegistry(root: notes)
        let c = SyncCoordinator(store: store, router: PageRouter(books: books, store: store),
                                tracker: QuietTracker(), publisher: publisher, notifier: notifier,
                                quietWindow: quietWindow)
        return (c, books, store)
    }

    /// The copy a page is in right now. Folder ids are generated, so a test asks rather than spells.
    func ref(_ page: PageID, _ books: BookRegistry) throws -> PageRef {
        PageRef(folder: try XCTUnwrap(books.current(for: page.surface)).folder, page: page)
    }

    func key(_ path: String) -> String { "/notes/pen/\(path)" }

    func testPublishUploadsOnlyGivenPathsAndSkipsWhatHasNotChanged() throws {
        let sync = try makeSync()
        let flow = makeFlow(publisher: sync)
        let a = PageID(section: 3, owner: 27, book: 5, page: 1)
        let b = PageID(section: 3, owner: 27, book: 5, page: 2)
        flow.coordinator.ingestLive([stroke(a, start: 1), stroke(b, start: 1)])
        let refA = try ref(a, flow.books), refB = try ref(b, flow.books)

        XCTAssertEqual(try sync.publish(paths: [refA.rawRelativePath]), 1)
        XCTAssertEqual(bucket.objects[key(refA.rawRelativePath)],
                       try Data(contentsOf: notes.appendingPathComponent(refA.rawRelativePath)))
        XCTAssertNil(bucket.objects[key(refB.rawRelativePath)], "page b was not asked for")

        XCTAssertEqual(try sync.publish(paths: [refA.rawRelativePath]), 0, "nothing new to send")
        XCTAssertEqual(try sync.publish(paths: [refB.rawRelativePath]), 1)
        XCTAssertEqual(bucket.requests.count, 2)
    }

    final class Drawer: PageImaging {
        var drawn = 0
        var text: (PageRef) -> String = { "png of \($0.description)" }
        func png(for ref: PageRef) -> Data? { drawn += 1; return Data(text(ref).utf8) }
    }

    func testAPageGoesUpAsItsStrokesAndThenItsPicture() throws {
        let pictures = PagePictures(root: notes, next: try makeSync())
        pictures.imaging = Drawer()
        let flow = makeFlow(publisher: pictures)
        let a = PageID(section: 3, owner: 27, book: 5, page: 7)
        flow.coordinator.ingestLive([stroke(a, start: 1)])
        let refA = try ref(a, flow.books)

        XCTAssertEqual(try pictures.publish(paths: [refA.rawRelativePath]), 2)
        let image = "books/\(refA.folder.name)/pages/p7.png"
        XCTAssertEqual(bucket.paths, [key(refA.rawRelativePath), key(image)],
                       "the picture is last, so it is the one to listen for")
        XCTAssertEqual(bucket.objects[key(image)], Data("png of \(refA.description)".utf8))
        XCTAssertEqual(bucket.requests.last?.value(forHTTPHeaderField: "content-type"), "image/png")
        XCTAssertEqual(try Data(contentsOf: notes.appendingPathComponent(image)), bucket.objects[key(image)],
                       "the folder and the bucket hold the same picture")
    }

    /// A reader on this Mac needs the picture as much as one behind a bucket does.
    func testWithNoBucketThePictureIsStillKeptInTheFolder() throws {
        let pictures = PagePictures(root: notes, next: try makeSync(connected: false))
        pictures.imaging = Drawer()
        let flow = makeFlow(publisher: pictures)
        let a = PageID(section: 3, owner: 27, book: 5, page: 7)
        flow.coordinator.ingestLive([stroke(a, start: 1)])
        let refA = try ref(a, flow.books)

        XCTAssertEqual(try pictures.publish(paths: [refA.rawRelativePath]), 0, "nothing went to a bucket")
        let image = notes.appendingPathComponent("books/\(refA.folder.name)/pages/p7.png")
        XCTAssertEqual(try Data(contentsOf: image), Data("png of \(refA.description)".utf8))
        XCTAssertTrue(bucket.requests.isEmpty)
    }

    /// A reader that listens for the picture must not be woken by a retry.
    func testAPictureThatHasNotChangedIsNotWrittenAgain() throws {
        let pictures = PagePictures(root: notes, next: try makeSync(connected: false))
        let drawer = Drawer()
        pictures.imaging = drawer
        let flow = makeFlow(publisher: pictures)
        let a = PageID(section: 3, owner: 27, book: 5, page: 7)
        flow.coordinator.ingestLive([stroke(a, start: 1)])
        let refA = try ref(a, flow.books)
        let image = notes.appendingPathComponent(PagePictures.imagePath(for: refA))

        _ = try pictures.publish(paths: [refA.rawRelativePath])
        let long = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: long], ofItemAtPath: image.path)
        _ = try pictures.publish(paths: [refA.rawRelativePath])
        XCTAssertEqual(drawer.drawn, 2)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: image.path)[.modificationDate] as? Date, long)

        drawer.text = { _ in "more ink" }
        _ = try pictures.publish(paths: [refA.rawRelativePath])
        XCTAssertEqual(try Data(contentsOf: image), Data("more ink".utf8))
    }

    /// With no bucket nothing is "unsent", so the picture is what says a page was left unfinished:
    /// one written just before the app stopped, or captured by a build that kept no pictures.
    func testAPageWithoutACurrentPictureIsRecoveredAndTheControlStripIsNot() throws {
        let pictures = PagePictures(root: notes, next: try makeSync(connected: false))
        pictures.imaging = Drawer()
        pictures.controlBooks = ["s3/o1013/b1"]
        let flow = makeFlow(publisher: pictures)
        flow.coordinator.controlBooks = pictures.controlBooks
        let a = PageID(section: 3, owner: 27, book: 5, page: 7)
        let strip = PageID(section: 3, owner: 1013, book: 1, page: 1)
        flow.coordinator.ingestLive([stroke(a, start: 1), stroke(strip, start: 2)])
        let refA = try ref(a, flow.books)

        XCTAssertEqual(pictures.dirtyPaths(under: ["books/"]), [refA.rawRelativePath])
        _ = try pictures.publish(paths: [refA.rawRelativePath])
        XCTAssertEqual(pictures.dirtyPaths(under: ["books/"]), [], "the picture is as new as the strokes")

        // More ink, later than the picture.
        let raw = notes.appendingPathComponent(refA.rawRelativePath)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: raw.path)
        let restarted = makeFlow(publisher: pictures)
        XCTAssertEqual(restarted.coordinator.recoverPending(), [refA])
    }

    /// The wait is on the pen, not on the page. A page left for another is not finished, so
    /// nothing goes while the pen is still doing anything — and then everything goes together.
    func testNothingUploadsUntilThePenHasBeenQuietAndThenEverythingDoes() throws {
        let rec = RecordingNotifier()
        let flow = makeFlow(publisher: try makeSync(), quietWindow: 30, notifier: rec)
        let c = flow.coordinator
        let a = PageID(section: 3, owner: 27, book: 5, page: 1)
        let b = PageID(section: 3, owner: 27, book: 5, page: 2)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        c.ingestLive([stroke(a, start: 1)], now: t0)
        c.ingestLive([stroke(b, start: 1)], now: t0.addingTimeInterval(20))
        XCTAssertEqual(Set(c.pendingPages), [try ref(a, flow.books), try ref(b, flow.books)])

        // Page a has been still for 35 seconds, but the pen wrote 15 seconds ago.
        c.tick(now: t0.addingTimeInterval(35))
        XCTAssertFalse(c.isPublishing)
        // A dot with no finished stroke behind it is still the pen doing something.
        c.penActive(at: t0.addingTimeInterval(40))
        c.tick(now: t0.addingTimeInterval(55))
        XCTAssertFalse(c.isPublishing)
        XCTAssertTrue(bucket.requests.isEmpty)

        let done = expectation(description: "published")
        c.onChange = { done.fulfill() }
        c.tick(now: t0.addingTimeInterval(71))
        wait(for: [done], timeout: 30)

        XCTAssertTrue(c.pendingPages.isEmpty)
        XCTAssertEqual(c.lastPublish?.pages, 2)
        // Both pages, and the notebook's record, which rides along with the first upload.
        XCTAssertEqual(c.lastPublish?.files, 3)
        XCTAssertNotNil(bucket.objects[key("books/\(try ref(a, flow.books).folder.name)/book.json")])
        XCTAssertNotNil(bucket.objects[key(try ref(b, flow.books).rawRelativePath)])
        XCTAssertTrue(rec.notices.isEmpty)
    }

    func testOfflineStrokesPublishImmediately() throws {
        let flow = makeFlow(publisher: try makeSync())
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
        XCTAssertNotNil(bucket.objects[key(try ref(a, flow.books).rawRelativePath)])
    }

    func testPublishFailureNotifiesAfterThreeAttemptsAndSaysWhenItIsOver() throws {
        let rec = RecordingNotifier()
        let flow = makeFlow(publisher: try makeSync(), quietWindow: 0, notifier: rec)
        let c = flow.coordinator
        let a = PageID(section: 3, owner: 27, book: 5, page: 1)
        c.ingestLive([stroke(a, start: 1)])
        bucket.offline = true
        var now = Date()
        func attempt(_ name: String) {
            let done = expectation(description: name)
            c.onChange = { done.fulfill() }
            c.tick(now: now)
            wait(for: [done], timeout: 5)
            now = now.addingTimeInterval(60 * 60) // past any backoff
        }
        for i in 1...3 { attempt("attempt \(i)") }
        XCTAssertEqual(c.consecutiveFailures, 3)
        XCTAssertEqual(rec.notices.map(\.key), ["publish-failed"])
        XCTAssertEqual(c.pendingPages, [try ref(a, flow.books)], "data stays pending")
        XCTAssertTrue(c.lastError?.contains("cannot be reached") == true, c.lastError ?? "nil")

        bucket.offline = false
        attempt("back online")
        XCTAssertEqual(rec.notices.map(\.key), ["publish-failed", "publish-recovered"])
        XCTAssertTrue(c.pendingPages.isEmpty)
        XCTAssertNil(c.lastError)
    }

    func testRecoverPendingAdoptsFilesThatWereNeverSent() throws {
        let sync = try makeSync()
        let flow = makeFlow(publisher: sync)
        let a = PageID(section: 3, owner: 27, book: 5, page: 1)
        let b = PageID(section: 3, owner: 27, book: 450, page: 12)
        flow.coordinator.ingestLive([stroke(a, start: 1), stroke(b, start: 1)])
        let refA = try ref(a, flow.books), refB = try ref(b, flow.books)
        XCTAssertEqual(try sync.publish(paths: [refA.rawRelativePath]), 1)
        flow.coordinator.ingestLive([stroke(a, start: 987)]) // a written after upload, b never sent

        // A restart: a new object, the same list on disk.
        let fresh = makeFlow(publisher: try makeSync()).coordinator
        XCTAssertTrue(fresh.pendingPages.isEmpty)
        let recovered = fresh.recoverPending()
        XCTAssertEqual(Set(recovered), [refA, refB])
        XCTAssertEqual(Set(fresh.pendingPages), [refA, refB])
        // Dated by mtime (just now), so not yet quiet…
        XCTAssertTrue(fresh.tracker.quietPages(now: Date(), window: 600).isEmpty)
        // …but quiet once the window passes.
        XCTAssertEqual(Set(fresh.tracker.quietPages(now: Date().addingTimeInterval(601), window: 600)), [refA, refB])
    }

    /// With no bucket the app is whole: pages are kept, nothing is pending for ever, nothing fails.
    /// The day a bucket is connected, everything already written is found and queued.
    func testNoBucketIsNotAFailureAndConnectingOneQueuesEverything() throws {
        let sync = try makeSync(connected: false)
        let rec = RecordingNotifier()
        let flow = makeFlow(publisher: sync, quietWindow: 0, notifier: rec)
        let c = flow.coordinator
        let a = PageID(section: 3, owner: 27, book: 5, page: 1)
        c.ingestLive([stroke(a, start: 1)])

        let done = expectation(description: "published")
        c.onChange = { done.fulfill() }
        c.tick()
        wait(for: [done], timeout: 5)
        XCTAssertTrue(c.pendingPages.isEmpty)
        XCTAssertEqual(c.lastPublish?.files, 0)
        XCTAssertTrue(bucket.requests.isEmpty)
        XCTAssertTrue(rec.notices.isEmpty)
        XCTAssertTrue(c.recoverPending().isEmpty, "nothing is owed to a bucket that does not exist")

        sync.connect(S3Client(account: try account(), transport: bucket))
        XCTAssertEqual(c.recoverPending(), [try ref(a, flow.books)])
    }

    /// The list of what was sent is true of one bucket. Point at another and it has had nothing.
    func testADifferentBucketStartsFromNothing() throws {
        let sync = try makeSync()
        let flow = makeFlow(publisher: sync)
        let a = PageID(section: 3, owner: 27, book: 5, page: 1)
        flow.coordinator.ingestLive([stroke(a, start: 1)])
        let path = try ref(a, flow.books).rawRelativePath
        XCTAssertEqual(try sync.publish(paths: [path]), 1)

        sync.connect(S3Client(account: try account(bucket: "elsewhere"), transport: bucket))
        XCTAssertEqual(try sync.publish(paths: [path]), 1)
        XCTAssertNotNil(bucket.objects["/elsewhere/pen/\(path)"])

        // And back: the first bucket's list was replaced by the second's, so it is sent again
        // rather than assumed.
        sync.connect(S3Client(account: try account(), transport: bucket))
        XCTAssertEqual(try sync.publish(paths: [path]), 1)
    }

    /// Readable files left in a notebook's `pages` were made from the record and are not the
    /// record; hidden files are the Finder's. Neither goes to the bucket.
    func testOnlyTheRecordGoesToTheBucket() throws {
        let flow = makeFlow(publisher: try makeSync())
        let a = PageID(section: 3, owner: 27, book: 5, page: 1)
        flow.coordinator.ingestLive([stroke(a, start: 1)])
        let folder = try ref(a, flow.books).folder
        let pages = notes.appendingPathComponent("\(folder.relativePath)/pages")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try Data("<svg/>".utf8).write(to: pages.appendingPathComponent("p1.svg"))
        try Data("x".utf8).write(to: notes.appendingPathComponent("books/.DS_Store"))
        try FileManager.default.createDirectory(at: notes.appendingPathComponent("pens"),
                                                withIntermediateDirectories: true)
        try Data("{\"mac\":\"aa\"}".utf8).write(to: notes.appendingPathComponent("pens/everyday.json"))
        try Data("{}".utf8).write(to: notes.appendingPathComponent("palette.json"))

        let done = expectation(description: "published")
        flow.coordinator.publishAll { _ in done.fulfill() }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(Set(bucket.objects.keys), [
            key("books/\(folder.name)/raw/p1.jsonl"), key("books/\(folder.name)/book.json"),
            key("pens/everyday.json"), key("palette.json"),
        ])
    }

    func testControlSurfaceTapsAreNotFiledAsNotes() throws {
        let flow = makeFlow(publisher: try makeSync())
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
