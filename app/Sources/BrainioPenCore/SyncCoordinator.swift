import Foundation

public protocol Publishing: AnyObject {
    var push: Bool { get set }
    func publish(paths: [String], message: String) throws -> String?
    /// Captured files written but never committed (survivors of a crash or restart).
    func dirtyPaths(under prefixes: [String]) -> [String]
}

extension GitPublisher: Publishing {}

/// Owns the flow from strokes to commits: file each stroke in the copy of the notebook it
/// belongs to, write it, track which pages are pending, publish pages once they are quiet, and
/// tell the person when publishing keeps failing.
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
        public let commit: String?
        public let pages: Int
    }

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

    /// The tracker lives in memory. On startup, adopt every uncommitted raw file as pending,
    /// dated by its modification time, so a restart never strands written strokes.
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
            Log.info("recovered \(recovered.count) uncommitted page(s): \(recovered.map(\.description).sorted().joined(separator: ", "))")
        }
        return recovered
    }

    /// Strokes received live from the pen.
    public func ingestLive(_ strokes: [Stroke], now: Date = Date()) {
        guard !strokes.isEmpty else { return }
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

    /// Where captured files live, as git pathspecs. Readable files are left out on purpose: they
    /// can be made again, and a commit full of regenerated SVGs hides the strokes that changed.
    static let capturePrefixes = ["books/", ModeLog.relativePath]

    /// Periodic check: publish whatever has gone quiet.
    public func tick(now: Date = Date()) {
        guard now >= nextRetry else { return }
        let quiet = tracker.quietPages(now: now, window: quietWindow)
        guard !quiet.isEmpty else { return }
        publish(pages: quiet, reason: "quiet for \(Int(quietWindow / 60)) min", now: now)
    }

    /// Publish everything pending regardless of quiet state (menu action).
    public func publishAll(now: Date = Date(), completion: ((Result<String?, Error>) -> Void)? = nil) {
        let pages = tracker.pendingPages
        guard !pages.isEmpty else {
            completion?(.success(nil))
            return
        }
        publish(pages: pages, reason: "manual", now: now, completion: completion)
    }

    /// Commit the given pages (and push them when pushing is on). Pages written again while the
    /// commit was in progress stay pending.
    public func publish(pages: [PageRef], reason: String, now: Date = Date(),
                        completion: ((Result<String?, Error>) -> Void)? = nil) {
        let sorted = pages.sorted { $0.description < $1.description }
        let snapshot = tracker.snapshot(of: sorted)
        let paths = sorted.map(\.rawRelativePath) + untrackedRawPaths()
        var message = "notes: \(sorted.count) page\(sorted.count == 1 ? "" : "s") (\(reason))\n\n"
        message += sorted.map { "- \($0.description)" }.joined(separator: "\n")
        inFlight = true
        workQueue.async { [self] in
            let result: Result<String?, Error>
            do {
                result = .success(try publisher.publish(paths: paths, message: message))
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

    /// Raw files that belong in a commit but never enter the tracker: control-surface taps and the
    /// mode log. They ride whatever publish happens next instead of starting one of their own. The
    /// files are on disk the moment they arrive, so waiting leaves them unpublished, never unsaved.
    private func untrackedRawPaths() -> [String] {
        publisher.dirtyPaths(under: Self.capturePrefixes).filter { path in
            guard let page = PageRef(rawRelativePath: path) else {
                // Anything under a book that is not a captured page is a readable file, and those
                // are regenerated rather than committed.
                return !path.contains("/pages/")
            }
            return controlBooks.contains(page.folder.surface)
        }
    }

    public var isPublishing: Bool { inFlight }

    /// When the next publish attempt is due after a failure; nil when nothing is being backed off.
    public var nextRetryAt: Date? { nextRetry == .distantPast ? nil : nextRetry }

    private func finish(_ result: Result<String?, Error>, snapshot: [PageRef: Date], pages: Int, now: Date) {
        switch result {
        case let .success(hash):
            tracker.clearIfUnchanged(snapshot)
            lastPublish = PublishRecord(date: now, commit: hash, pages: pages)
            if consecutiveFailures > 0 {
                notifier.post(Notice(key: "publish-recovered", title: "Brainio Pen is syncing again",
                                     body: "Notes are being committed normally."))
            }
            consecutiveFailures = 0
            lastError = nil
            nextRetry = .distantPast
            Log.info("published \(pages) page(s)\(hash.map { " as \($0)" } ?? " (nothing new)")")
        case let .failure(error):
            consecutiveFailures += 1
            lastError = "\(error)"
            // Back off: 1, 2, 4, … minutes, capped at 30.
            let delay = min(30.0, pow(2.0, Double(consecutiveFailures - 1))) * 60
            nextRetry = now.addingTimeInterval(delay)
            Log.error("publish failed (\(consecutiveFailures)x): \(error)")
            if consecutiveFailures >= 3 {
                notifier.post(Notice(key: "publish-failed", title: "Brainio Pen cannot publish notes",
                                     body: "\(consecutiveFailures) attempts failed. Strokes are safe on disk. Last error: \(error)"))
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
