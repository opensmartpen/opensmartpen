import XCTest
@testable import BrainioPenCore

/// Two identical pads report the same Ncode book, so a second copy has to be decided rather than
/// assumed — and it is decided, never asked (ADR-002). When the signals disagree the answer is the
/// new copy: a wrong split is a second book you can see and repair, while a wrong merge interleaves
/// two notebooks inside one captured file and can only be repaired by cutting it.
final class CopyWatcherTests: XCTestCase {
    private let book = "s3/o27/b450"
    private let day = 86_400_000

    private func page(_ n: Int, at ms: Int, overlap: Double = 0) -> CopyEvidence {
        CopyEvidence(surface: book, page: n, at: ms, inkOverlap: overlap)
    }

    func testOrdinaryWritingDecidesNothing() {
        let w = CopyWatcher()
        XCTAssertNil(w.decide(page(1, at: 0)))
        XCTAssertNil(w.decide(page(2, at: day)))
        XCTAssertNil(w.decide(page(3, at: 2 * day)))
    }

    func testInkOnInkDecidesOnItsOwn() {
        let w = CopyWatcher()
        _ = w.decide(page(1, at: 0))
        // Same sheet, same moment, but the new strokes land where the old ones are. One sheet
        // cannot hold the same writing twice.
        XCTAssertEqual(w.decide(page(1, at: 60_000, overlap: 0.6)), .inkOverlap)
    }

    func testALittleOverlapIsAnnotationNotANewNotebook() {
        let w = CopyWatcher()
        _ = w.decide(page(1, at: 0))
        XCTAssertNil(w.decide(page(1, at: 60_000, overlap: 0.05)),
                     "adding a line between existing ones touches some of the same ink")
    }

    func testStartingAgainAtTheFrontAfterASilenceDecides() {
        let w = CopyWatcher()
        for n in 1...14 { _ = w.decide(page(n, at: n * 1000)) }
        XCTAssertEqual(w.decide(page(1, at: 3 * day)), .sequenceRestart)
    }

    func testReturningToAnEarlyPageOnTheSameDayDecidesNothing() {
        let w = CopyWatcher()
        for n in 1...14 { _ = w.decide(page(n, at: n * 1000)) }
        // Flipping back to page 1 an hour later is ordinary use, not a new pad.
        XCTAssertNil(w.decide(page(1, at: 3_600_000)))
    }

    func testASilenceAloneNeverDecides() {
        // A notebook is allowed to rest. Months of nothing, then writing on from where it stopped,
        // is the same notebook.
        let w = CopyWatcher()
        _ = w.decide(page(40, at: 0))
        XCTAssertNil(w.decide(page(41, at: 90 * day)))
        XCTAssertNil(w.decide(page(80, at: 120 * day)), "a distant page after a silence is still not a signal")
    }

    func testTheFrontOfABarelyStartedBookIsNotARestart() {
        let w = CopyWatcher()
        _ = w.decide(page(1, at: 0))
        _ = w.decide(page(2, at: 1000))
        XCTAssertNil(w.decide(page(1, at: 5 * day)), "the book was never written far past its front")
    }

    func testDecidingTwiceInARowNeedsFreshEvidence() {
        let w = CopyWatcher()
        for n in 1...14 { _ = w.decide(page(n, at: n * 1000)) }
        XCTAssertEqual(w.decide(page(1, at: 3 * day)), .sequenceRestart)
        // The new copy starts at page 1 and is written forward. That is not another new copy.
        XCTAssertNil(w.decide(page(2, at: 4 * day)))
        XCTAssertNil(w.decide(page(3, at: 5 * day)))
    }

    func testWhatIsAlreadyOnDiskIsAdoptedSoARestartIsNotAFreshNotebook() {
        let w = CopyWatcher()
        w.adopt(surface: book, pages: Array(1...14), at: 0)
        XCTAssertEqual(w.decide(page(1, at: 3 * day)), .sequenceRestart,
                       "the book's reach survives a restart of the app")
    }
}

/// Ink overlap is asked as "do the new dots land where the old dots are", not "do the bounding
/// boxes touch". Two pages written full always overlap as boxes, and so do a page of notes and a
/// line added in its margin — the grid is what tells those apart.
final class InkGridTests: XCTestCase {
    private func dots(_ points: [(Double, Double)]) -> [DotSample] {
        points.map { DotSample(x: $0.0, y: $0.1, force: 0.5, dt: 0) }
    }

    func testAnEmptyGridOverlapsNothing() {
        XCTAssertTrue(InkGrid().isEmpty)
        XCTAssertEqual(InkGrid().share(of: dots([(1, 1)])), 0)
    }

    func testWritingOverTheSameInkIsMostlyOverlap() {
        let grid = InkGrid(dots: dots([(10, 10), (10.2, 10.1), (11, 10), (12, 10)]))
        XCTAssertGreaterThan(grid.share(of: dots([(10, 10), (11, 10), (12, 10)])), 0.9)
    }

    func testWritingBesideTheSameInkIsNotOverlap() {
        // A line written between two existing lines, one cell away.
        let grid = InkGrid(dots: dots([(10, 10), (11, 10), (12, 10)]))
        XCTAssertEqual(grid.share(of: dots([(10, 12), (11, 12), (12, 12)])), 0)
    }

    func testTwoPagesOfDifferentWritingOverlapOnlyWhereTheInkMeets() {
        let grid = InkGrid(dots: dots((0..<20).map { (Double($0), 5.0) }))
        // A second hand writing elsewhere on the sheet, crossing the first line once.
        let crossing = dots((0..<20).map { (10.0, Double($0)) })
        XCTAssertLessThan(grid.share(of: crossing), 0.25, "crossing once is not writing twice")
    }
}
