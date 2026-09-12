import Foundation
@testable import BrainioPenCore
import XCTest

final class StrokeAssemblerTests: XCTestCase {
    let page = PageID(section: 3, owner: 27, book: 1, page: 1)
    let other = PageID(section: 3, owner: 27, book: 1, page: 2)
    let ctx = StrokeAssembler.Context(penMac: "M", firmware: "F")

    func dot(_ x: Double, _ dt: Int = 8) -> DotSample { DotSample(x: x, y: 1, force: 0.5, dt: dt) }

    func testDownMoveUpProducesOneStroke() {
        let a = StrokeAssembler()
        XCTAssertNil(a.feed(event: .down, page: page, sample: dot(1, 5), timeMs: 100, context: ctx))
        XCTAssertNil(a.feed(event: .move, page: page, sample: dot(2), timeMs: 108, context: ctx))
        XCTAssertNil(a.feed(event: .move, page: page, sample: dot(3), timeMs: 116, context: ctx))
        let s = a.feed(event: .up, page: page, sample: dot(3), timeMs: 124, context: ctx)
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.dots.count, 3, "Up repeating the last point is not stored twice")
        XCTAssertEqual(s?.dots.first?.dt, 0, "first dot always has dt 0")
        XCTAssertEqual(s?.start, 100)
        XCTAssertEqual(s?.end, 124)
        XCTAssertEqual(s?.source, .live)
        XCTAssertFalse(a.hasOpenStroke)
    }

    func testMissingUpClosesOnNextDown() {
        let a = StrokeAssembler()
        a.feed(event: .down, page: page, sample: dot(1), timeMs: 0, context: ctx)
        a.feed(event: .move, page: page, sample: dot(2), timeMs: 8, context: ctx)
        let closed = a.feed(event: .down, page: page, sample: dot(9), timeMs: 500, context: ctx)
        XCTAssertEqual(closed?.dots.count, 2)
        XCTAssertEqual(closed?.end, 8)
        XCTAssertTrue(a.hasOpenStroke)
    }

    func testPageChangeMidStrokeSplits() {
        let a = StrokeAssembler()
        a.feed(event: .down, page: page, sample: dot(1), timeMs: 0, context: ctx)
        let closed = a.feed(event: .move, page: other, sample: dot(2), timeMs: 8, context: ctx)
        XCTAssertEqual(closed?.page, page)
        let s = a.feed(event: .up, page: other, sample: dot(3), timeMs: 16, context: ctx)
        XCTAssertEqual(s?.page, other)
    }

    func testMoveWithoutDownStartsStroke() {
        let a = StrokeAssembler()
        XCTAssertNil(a.feed(event: .move, page: page, sample: dot(1), timeMs: 0, context: ctx))
        XCTAssertTrue(a.hasOpenStroke)
        XCTAssertNotNil(a.flush())
        XCTAssertNil(a.flush())
    }

    func testUpWithoutStrokeIsIgnored() {
        let a = StrokeAssembler()
        XCTAssertNil(a.feed(event: .up, page: page, sample: dot(1), timeMs: 0, context: ctx))
    }
}
