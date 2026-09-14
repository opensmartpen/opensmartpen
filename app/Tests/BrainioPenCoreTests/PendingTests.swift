import XCTest
@testable import BrainioPenCore

/// The panel counts each waiting page down to its publish time, so the tracker has to report
/// when a page was first and last written, not just that it is dirty.
final class PendingTests: XCTestCase {
    private let pad = BookFolder(surface: "s3/o27/b450", id: "7f3a9c")
    private var p1: PageRef { PageRef(folder: pad, page: PageID(section: 3, owner: 27, book: 450, page: 1)) }
    private var p2: PageRef { PageRef(folder: pad, page: PageID(section: 3, owner: 27, book: 450, page: 2)) }
    private let t0 = Date(timeIntervalSince1970: 1_757_530_000)

    func testFirstWriteIsKeptWhileLastWriteMoves() {
        let tracker = QuietTracker()
        tracker.touch([p1], at: t0)
        tracker.touch([p1], at: t0.addingTimeInterval(120))

        let entry = try? XCTUnwrap(tracker.pending.first)
        XCTAssertEqual(entry?.page, p1)
        XCTAssertEqual(entry?.first, t0)
        XCTAssertEqual(entry?.last, t0.addingTimeInterval(120))
    }

    func testDeadlineIsTheLastStrokePlusTheQuietWindow() {
        let tracker = QuietTracker()
        tracker.touch([p1], at: t0)
        let entry = tracker.pending[0]
        XCTAssertEqual(entry.deadline(window: 600), t0.addingTimeInterval(600))
        // Which is exactly when quietPages agrees to publish it.
        XCTAssertTrue(tracker.quietPages(now: entry.deadline(window: 600), window: 600).contains(p1))
    }

    func testMostRecentlyWrittenPageIsListedFirst() {
        let tracker = QuietTracker()
        tracker.touch([p1], at: t0)
        tracker.touch([p2], at: t0.addingTimeInterval(60))
        XCTAssertEqual(tracker.pending.map(\.page), [p2, p1])
    }

    func testDrainedPagesAreImmediatelyOverdue() {
        // Offline strokes were written long ago; they should not sit through another quiet window.
        let tracker = QuietTracker()
        tracker.markQuiet([p1])
        let entry = tracker.pending[0]
        XCTAssertEqual(entry.first, .distantPast)
        XCTAssertLessThan(entry.deadline(window: 600), t0)
    }

    func testClearingAPageForgetsBothTimes() {
        let tracker = QuietTracker()
        tracker.touch([p1, p2], at: t0)
        tracker.clear([p1])
        XCTAssertEqual(tracker.pending.map(\.page), [p2])
        tracker.touch([p1], at: t0.addingTimeInterval(300))
        XCTAssertEqual(tracker.pending.first(where: { $0.page == p1 })?.first, t0.addingTimeInterval(300))
    }
}
