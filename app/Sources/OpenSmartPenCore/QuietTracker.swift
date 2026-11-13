import Foundation

/// Remembers which pages have unpublished strokes and when they were last written,
/// so the publisher can pick the ones that have gone quiet.
public final class QuietTracker {
    /// A page waiting to be published, with the times the panel needs to count it down.
    public struct Entry: Equatable {
        public let page: PageRef
        /// First unpublished stroke on this page.
        public let first: Date
        /// Most recent stroke. The page publishes `window` after this.
        public let last: Date

        public init(page: PageRef, first: Date, last: Date) {
            self.page = page
            self.first = first
            self.last = last
        }

        /// When this page becomes publishable.
        public func deadline(window: TimeInterval) -> Date { last.addingTimeInterval(window) }
    }

    private var lastWrite: [PageRef: Date] = [:]
    private var firstWrite: [PageRef: Date] = [:]

    public init() {}

    public var pendingPages: [PageRef] { Array(lastWrite.keys) }
    public var isEmpty: Bool { lastWrite.isEmpty }

    /// Everything waiting, most recently written first — the order the panel lists them in.
    public var pending: [Entry] {
        lastWrite.map { Entry(page: $0.key, first: firstWrite[$0.key] ?? $0.value, last: $0.value) }
            .sorted { ($0.last, $0.page.description) > ($1.last, $1.page.description) }
    }

    /// Record a live write. The page is quiet again once `window` has elapsed.
    public func touch(_ pages: some Sequence<PageRef>, at time: Date = Date()) {
        for p in pages {
            lastWrite[p] = time
            if firstWrite[p] == nil { firstWrite[p] = time }
        }
    }

    /// Record strokes that were already old when they arrived (offline drain).
    /// They are quiet immediately unless the page is also being written live right now.
    public func markQuiet(_ pages: some Sequence<PageRef>) {
        for p in pages where lastWrite[p] == nil {
            lastWrite[p] = .distantPast
            firstWrite[p] = .distantPast
        }
    }

    public func quietPages(now: Date = Date(), window: TimeInterval) -> [PageRef] {
        lastWrite.filter { now.timeIntervalSince($0.value) >= window }.map(\.key)
    }

    public func clear(_ pages: some Sequence<PageRef>) {
        for p in pages {
            lastWrite.removeValue(forKey: p)
            firstWrite.removeValue(forKey: p)
        }
    }

    public func lastWriteTime(_ page: PageRef) -> Date? { lastWrite[page] }
}
