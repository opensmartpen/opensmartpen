import Foundation

/// Somewhere captured files are sent once they have gone quiet. In the app that is a bucket.
public protocol Publishing: AnyObject {
    /// Send these files, given relative to the notes folder. Returns how many actually went:
    /// a file that has not changed since it was last sent is not sent again.
    func publish(paths: [String]) throws -> Int
    /// Captured files written but never sent (survivors of a crash, a restart, or a day offline).
    func dirtyPaths(under prefixes: [String]) -> [String]
}

/// Owns the flow from strokes to the bucket: file each stroke in the copy of the notebook it
/// belongs to, write it, track which pages are pending, upload pages once they are quiet, and
/// tell the person when uploading keeps failing.
public final class SyncCoordinator {
    public let store: RawStore
    /// Decides which copy of a notebook an arriving stroke belongs to (ADR-002).
    public let router: PageRouter
    public let tracker: QuietTracker
    public let publisher: Publishing
    public let notifier: Notifier
    public var quietWindow: TimeInterval
    /// Books that are control surfaces; strokes on them never become notes.
    public var controlBooks: Set<String> = []
    /// Called for every tap on a control surface, so callers can act on it or map it.
    public var onControlTap: ((Stroke) -> Void)?
    /// Where ink colour and line width changes are recorded. Nil leaves the strip inert.
    public var modeLog: ModeLog?

    public struct PublishRecord: Equatable {
        public let date: Date
        /// Files that went up. Nought when no bucket is connected, or when nothing had changed.
        public let files: Int
        public let pages: Int
    }

    /// When a pen last did anything at all: a dot on any page, a tap on the control strip. The
    /// upload waits on this and not on each page. A page is not finished because the pen moved
    /// to another one, and whatever reads the bucket should get a sitting's pages together, once.
    public private(set) var lastActivity: Date = .distantPast

    /// Called for every event a pen reports. Cheap enough for every dot.
    public func penActive(at time: Date = Date()) {
        if time > lastActivity { lastActivity = time }
    }

    /// When the pending pages will go, if no pen does anything before then.
    public var uploadDue: Date { lastActivity.addingTimeInterval(quietWindow) }

    public private(set) var lastPublish: PublishRecord?
    public private(set) var consecutiveFailures = 0
    public private(set) var lastError: String?
    /// Fired on the main queue after every publish attempt.
    public var onChange: (() -> Void)?
    /// Fired after strokes from pen memory are on disk, with the pages they landed on. Anything
    /// that read those pages earlier is now short of them.
    public var onOfflineStored: ((Set<PageRef>) -> Void)?

    private let workQueue = DispatchQueue(label: "com.brainio.pen.publish")
    private var nextRetry: Date = .distantPast
    private var inFlight = false

    public init(store: RawStore, router: PageRouter, tracker: QuietTracker, publisher: Publishing,
                notifier: Notifier, quietWindow: TimeInterval) {
        self.store = store
        self.router = router
        self.tracker = tracker
        self.publisher = publisher
        self.notifier = notifier
        self.quietWindow = quietWindow
    }

    public var pendingPages: [PageRef] { tracker.pendingPages }

    /// The tracker lives in memory. On startup, and whenever a bucket is connected, adopt every
    /// raw file that has not been sent as pending, dated by its modification time, so a restart
    /// never strands written strokes.
    /// Returns the recovered pages.
    @discardableResult
    public func recoverPending() -> [PageRef] {
        var recovered: [PageRef] = []
        for path in publisher.dirtyPaths(under: Self.capturePrefixes) {
            guard let page = PageRef(rawRelativePath: path) else { continue }
            let url = store.root.appendingPathComponent(path)
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            guard !admit([page]).isEmpty else { continue }
            tracker.touch([page], at: mtime)
            recovered.append(page)
        }
        if !recovered.isEmpty {
            Log.info("recovered \(recovered.count) unsent page(s): \(recovered.map(\.description).sorted().joined(separator: ", "))")
        }
        return recovered
    }

    /// Strokes received live from the pen.
    public func ingestLive(_ strokes: [Stroke], now: Date = Date()) {
        guard !strokes.isEmpty else { return }
        penActive(at: now)
        decodeControlTaps(strokes)
        do {
            let pages = try write(strokes, now: now)
            tracker.touch(admit(pages), at: now)
            Log.debug("live: \(strokes.count) stroke(s) on \(pages.map(\.description).sorted().joined(separator: ", "))")
        } catch {
            Log.error("writing live strokes failed: \(error)")
            notifier.post(Notice(key: "store-write", title: "Brainio Pen cannot write notes",
                                 body: "Writing to \(store.root.path) failed: \(error.localizedDescription)"))
        }
    }

    /// Strokes drained from pen memory. Returns the pages they landed on.
    @discardableResult
    public func ingestOffline(_ strokes: [Stroke], now: Date = Date()) -> Set<PageRef> {
        guard !strokes.isEmpty else { return [] }
        decodeControlTaps(strokes)
        do {
            let pages = Set(admit(try write(strokes, now: now)))
            tracker.markQuiet(pages)
            Log.info("offline: \(strokes.count) stroke(s) on \(pages.count) page(s)")
            onOfflineStored?(pages)
            return pages
        } catch {
            Log.error("writing offline strokes failed: \(error)")
            notifier.post(Notice(key: "store-write", title: "Brainio Pen cannot write notes",
                                 body: "Writing to \(store.root.path) failed: \(error.localizedDescription)"))
            return []
        }
    }

    /// Reports and decodes taps on a control surface.
    ///
    /// The taps are stored in raw like any other stroke — the pen saw them, so raw says so, which
    /// is ADR-001 — but they never enter the tracker, so a tap alone never starts a publish
    /// countdown and never appears in the pending list as an unclickable notebook.
    private func decodeControlTaps(_ strokes: [Stroke]) {
        guard !controlBooks.isEmpty else { return }
        for s in strokes where controlBooks.contains(s.page.surface) {
            let x = s.dots.map(\.x).reduce(0, +) / Double(max(1, s.dots.count))
            let y = s.dots.map(\.y).reduce(0, +) / Double(max(1, s.dots.count))
            let button = ControlMap.button(for: s)
            Log.info(String(format: "control tap on %@ at x %.2f y %.2f cells -> %@",
                            s.page.description, x, y, describe(button)))
            if let button { modeLog?.record(button, at: s.start, client: .pen, tap: s.id) }
            onControlTap?(s)
        }
    }

    private func describe(_ button: ControlButton?) -> String {
        switch button {
        case let .ink(c): return "ink \(c.rawValue)"
        case let .width(w): return "width \(w.rawValue)"
        case nil: return "no button"
        }
    }

    /// The single point at which a page may enter the tracker. Control books never do, whether
    /// they arrive live, from a drain, or from recovery after a restart.
    private func admit(_ pages: some Sequence<PageRef>) -> [PageRef] {
        pages.filter { !controlBooks.contains($0.folder.surface) }
    }

    /// Route each stroke to its copy, then write it there. Routing comes first because a stroke
    /// written into the wrong copy cannot be moved back out of the file it landed in.
    private func write(_ strokes: [Stroke], now: Date) throws -> Set<PageRef> {
        var touched: Set<PageRef> = []
        for group in router.route(strokes) {
            touched.formUnion(try store.append(group.strokes, to: group.folder, now: now))
        }
        return touched
    }

    /// Everything that is the record: the pages, what each notebook and pen is called, and how
    /// the ink is to be read. Anything else in the folder was made from these and can be made again.
    static let capturePrefixes = ["books/", "pens/", ModeLog.relativePath, Palette.relativePath]

    /// Periodic check: once no pen has reported anything for the quiet window, upload every
    /// page that is waiting.
    public func tick(now: Date = Date()) {
        guard now >= nextRetry, !inFlight else { return }
        guard now.timeIntervalSince(lastActivity) >= quietWindow else { return }
        let waiting = tracker.pendingPages
        guard !waiting.isEmpty else { return }
        publish(pages: waiting, reason: "no pen event for \(Int(quietWindow)) s", now: now)
    }

    /// Publish everything pending regardless of quiet state (menu action).
    ///
    /// Runs even with no page pending: a notebook given a new title, or a pen a new name, is a
    /// changed file with no page to ride along with, and this is how it gets sent today.
    public func publishAll(now: Date = Date(), completion: ((Result<Int, Error>) -> Void)? = nil) {
        publish(pages: tracker.pendingPages, reason: "manual", now: now, completion: completion)
    }

    /// Upload the given pages. Pages written again while the upload was in progress stay pending.
    public func publish(pages: [PageRef], reason: String, now: Date = Date(),
                        completion: ((Result<Int, Error>) -> Void)? = nil) {
        let sorted = pages.sorted { $0.description < $1.description }
        let snapshot = tracker.snapshot(of: sorted)
        // The small files first. They say what the pages are, so they should be there before
        // the pages are.
        let paths = untrackedRawPaths() + sorted.map(\.rawRelativePath)
        Log.debug("sync (\(reason)): \(sorted.map(\.description).joined(separator: ", "))")
        inFlight = true
        workQueue.async { [self] in
            let result: Result<Int, Error>
            do {
                result = .success(try publisher.publish(paths: paths))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                self.inFlight = false
                self.finish(result, snapshot: snapshot, pages: sorted.count, now: now)
                completion?(result)
            }
        }
    }

    /// Files that belong in the bucket but never enter the tracker: control-surface taps, the
    /// mode log, the notebook and pen records. They ride whatever upload happens next instead of
    /// starting one of their own. The files are on disk the moment they arrive, so waiting leaves
    /// them unsent, never unsaved.
    private func untrackedRawPaths() -> [String] {
        publisher.dirtyPaths(under: Self.capturePrefixes).filter { path in
            guard let page = PageRef(rawRelativePath: path) else {
                // Anything under a book's `pages` was made from the record. The one such file the
                // bucket gets is the PNG, and that is drawn at upload rather than read from here.
                return !path.contains("/pages/")
            }
            return controlBooks.contains(page.folder.surface)
        }
    }

    public var isPublishing: Bool { inFlight }

    /// When the next publish attempt is due after a failure; nil when nothing is being backed off.
    public var nextRetryAt: Date? { nextRetry == .distantPast ? nil : nextRetry }

    private func finish(_ result: Result<Int, Error>, snapshot: [PageRef: Date], pages: Int, now: Date) {
        switch result {
        case let .success(files):
            tracker.clearIfUnchanged(snapshot)
            lastPublish = PublishRecord(date: now, files: files, pages: pages)
            if consecutiveFailures >= 3 {
                notifier.post(Notice(key: "publish-recovered", title: "Brainio Pen is syncing again",
                                     body: "Notes are being uploaded normally."))
            }
            consecutiveFailures = 0
            lastError = nil
            nextRetry = .distantPast
            if files > 0 { Log.info("uploaded \(files) file(s) for \(pages) page(s)") }
        case let .failure(error):
            consecutiveFailures += 1
            // Back off: 1, 2, 4, … minutes, capped at 30.
            let delay = min(30.0, pow(2.0, Double(consecutiveFailures - 1))) * 60
            nextRetry = now.addingTimeInterval(delay)
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.error("upload failed (\(consecutiveFailures)x): \(lastError ?? "")")
            if consecutiveFailures >= 3 {
                notifier.post(Notice(key: "publish-failed", title: "Brainio Pen cannot upload notes",
                                     body: "\(consecutiveFailures) attempts failed. Strokes are safe on this Mac. \(lastError ?? "")"))
            }
        }
        onChange?()
    }
}

extension QuietTracker {
    /// Last-write times for the given pages, used to detect writes that landed during a publish.
    func snapshot(of pages: [PageRef]) -> [PageRef: Date] {
        var out: [PageRef: Date] = [:]
        for p in pages { if let d = lastWriteTime(p) { out[p] = d } }
        return out
    }

    func clearIfUnchanged(_ snapshot: [PageRef: Date]) {
        for (page, date) in snapshot where lastWriteTime(page) == date {
            clear([page])
        }
    }
}
