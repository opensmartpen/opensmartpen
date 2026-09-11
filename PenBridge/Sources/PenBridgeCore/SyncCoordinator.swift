import Foundation

public protocol Publishing: AnyObject {
    var push: Bool { get set }
    func publish(paths: [String], message: String) throws -> String?
    /// Raw files written but never committed (survivors of a crash or restart).
    func dirtyPaths(under prefix: String) -> [String]
}

extension GitPublisher: Publishing {}

/// Owns the flow from strokes to commits: write raw files, track which pages are pending,
/// publish pages once they are quiet, and tell the person when publishing keeps failing.
public final class SyncCoordinator {
    public let store: RawStore
    public let tracker: QuietTracker
    public let publisher: Publishing
    public let notifier: Notifier
    public var quietWindow: TimeInterval
    /// Books that are control surfaces; strokes on them never become notes.
    public var controlBooks: Set<String> = []
    /// Called for every tap on a control surface, so callers can act on it or map it.
    public var onControlTap: ((Stroke) -> Void)?

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

    private let workQueue = DispatchQueue(label: "penbridge.publish")
    private var nextRetry: Date = .distantPast
    private var inFlight = false

    public init(store: RawStore, tracker: QuietTracker, publisher: Publishing, notifier: Notifier, quietWindow: TimeInterval) {
        self.store = store
        self.tracker = tracker
        self.publisher = publisher
        self.notifier = notifier
        self.quietWindow = quietWindow
    }

    public var pendingPages: [PageID] { tracker.pendingPages }

    /// The tracker lives in memory. On startup, adopt every uncommitted raw file as pending,
    /// dated by its modification time, so a restart never strands written strokes.
    /// Returns the recovered pages.
    @discardableResult
    public func recoverPending() -> [PageID] {
        var recovered: [PageID] = []
        for path in publisher.dirtyPaths(under: "raw/") {
            guard let page = PageID(rawRelativePath: path) else { continue }
            let url = store.root.appendingPathComponent(path)
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
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
        let strokes = separateControlTaps(strokes)
        guard !strokes.isEmpty else { return }
        do {
            let pages = try store.append(strokes, now: now)
            tracker.touch(pages, at: now)
            Log.debug("live: \(strokes.count) stroke(s) on \(pages.map(\.description).sorted().joined(separator: ", "))")
        } catch {
            Log.error("writing live strokes failed: \(error)")
            notifier.post(Notice(key: "store-write", title: "PenBridge cannot write notes",
                                 body: "Writing to \(store.root.path) failed: \(error.localizedDescription)"))
        }
    }

    /// Strokes drained from pen memory. Returns the pages they landed on.
    @discardableResult
    public func ingestOffline(_ strokes: [Stroke], now: Date = Date()) -> Set<PageID> {
        let strokes = separateControlTaps(strokes)
        guard !strokes.isEmpty else { return [] }
        do {
            let pages = try store.append(strokes, now: now)
            tracker.markQuiet(pages)
            Log.info("offline: \(strokes.count) stroke(s) on \(pages.count) page(s)")
            return pages
        } catch {
            Log.error("writing offline strokes failed: \(error)")
            notifier.post(Notice(key: "store-write", title: "PenBridge cannot write notes",
                                 body: "Writing to \(store.root.path) failed: \(error.localizedDescription)"))
            return []
        }
    }

    /// Removes strokes made on a control surface, reporting each one, and returns the rest.
    private func separateControlTaps(_ strokes: [Stroke]) -> [Stroke] {
        guard !controlBooks.isEmpty else { return strokes }
        var notes: [Stroke] = []
        for s in strokes {
            if controlBooks.contains(s.page.bookKey) {
                let x = s.dots.map(\.x).reduce(0, +) / Double(max(1, s.dots.count))
                let y = s.dots.map(\.y).reduce(0, +) / Double(max(1, s.dots.count))
                Log.info(String(format: "control tap on %@ at x %.2f y %.2f cells (%.1f, %.1f mm)",
                                s.page.description, x, y, x * 2.371, y * 2.371))
                onControlTap?(s)
            } else {
                notes.append(s)
            }
        }
        return notes
    }

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

    /// Commit and push the given pages. Pages written again while the commit was in progress stay pending.
    public func publish(pages: [PageID], reason: String, now: Date = Date(),
                        completion: ((Result<String?, Error>) -> Void)? = nil) {
        let sorted = pages.sorted { $0.description < $1.description }
        let snapshot = tracker.snapshot(of: sorted)
        let paths = sorted.map(\.rawRelativePath)
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

    public var isPublishing: Bool { inFlight }

    private func finish(_ result: Result<String?, Error>, snapshot: [PageID: Date], pages: Int, now: Date) {
        switch result {
        case let .success(hash):
            tracker.clearIfUnchanged(snapshot)
            lastPublish = PublishRecord(date: now, commit: hash, pages: pages)
            if consecutiveFailures > 0 {
                notifier.post(Notice(key: "publish-recovered", title: "PenBridge is syncing again",
                                     body: "Notes are being committed and pushed normally."))
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
                notifier.post(Notice(key: "publish-failed", title: "PenBridge cannot publish notes",
                                     body: "\(consecutiveFailures) attempts failed. Strokes are safe on disk. Last error: \(error)"))
            }
        }
        onChange?()
    }
}

extension QuietTracker {
    /// Last-write times for the given pages, used to detect writes that landed during a publish.
    func snapshot(of pages: [PageID]) -> [PageID: Date] {
        var out: [PageID: Date] = [:]
        for p in pages { if let d = lastWriteTime(p) { out[p] = d } }
        return out
    }

    func clearIfUnchanged(_ snapshot: [PageID: Date]) {
        for (page, date) in snapshot where lastWriteTime(page) == date {
            clear([page])
        }
    }
}
