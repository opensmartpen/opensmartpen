import Foundation

/// Remembers which pages have unpublished strokes and when they were last written,
/// so the publisher can pick the ones that have gone quiet.
public final class QuietTracker {
    private var lastWrite: [PageID: Date] = [:]

    public init() {}

    public var pendingPages: [PageID] { Array(lastWrite.keys) }
    public var isEmpty: Bool { lastWrite.isEmpty }

    /// Record a live write. The page is quiet again once `window` has elapsed.
    public func touch(_ pages: some Sequence<PageID>, at time: Date = Date()) {
        for p in pages { lastWrite[p] = time }
    }

    /// Record strokes that were already old when they arrived (offline drain).
    /// They are quiet immediately unless the page is also being written live right now.
    public func markQuiet(_ pages: some Sequence<PageID>) {
        for p in pages where lastWrite[p] == nil { lastWrite[p] = .distantPast }
    }

    public func quietPages(now: Date = Date(), window: TimeInterval) -> [PageID] {
        lastWrite.filter { now.timeIntervalSince($0.value) >= window }.map(\.key)
    }

    public func clear(_ pages: some Sequence<PageID>) {
        for p in pages { lastWrite.removeValue(forKey: p) }
    }

    public func lastWriteTime(_ page: PageID) -> Date? { lastWrite[page] }
}
