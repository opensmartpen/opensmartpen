import XCTest
@testable import BrainioPenCore

final class UnreadInkTests: XCTestCase {
    func testNothingGatheredReportsNothing() {
        var unread = UnreadInk()
        XCTAssertNil(unread.take())
    }

    func testOnlyTheFirstErrorOfAWindowStartsTheClock() {
        var unread = UnreadInk()
        XCTAssertTrue(unread.record(code: 3))
        XCTAssertFalse(unread.record(code: 3))
        _ = unread.take()
        XCTAssertTrue(unread.record(code: 3))
    }

    func testAStrayErrorIsLoggedButNotWorthTelling() {
        var unread = UnreadInk()
        let start = Date(timeIntervalSince1970: 1_000)
        unread.record(code: 3, at: start)
        unread.record(code: 5, at: start.addingTimeInterval(1))
        let report = unread.take()
        XCTAssertEqual(report?.count, 2)
        XCTAssertEqual(report?.codes, [3: 1, 5: 1])
        XCTAssertEqual(report?.since, start)
        XCTAssertEqual(report?.worthTelling, false)
        XCTAssertEqual(report?.line, "2 sample(s) the pen could not read (code 3 ×1, code 5 ×1)")
        XCTAssertNil(unread.take())
    }

    func testARunOfErrorsIsWorthTelling() {
        var unread = UnreadInk()
        for _ in 0..<UnreadInk.tellingCount { unread.record(code: 3) }
        XCTAssertEqual(unread.take()?.worthTelling, true)
    }
}
