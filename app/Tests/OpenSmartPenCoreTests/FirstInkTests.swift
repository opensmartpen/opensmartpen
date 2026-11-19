import XCTest
@testable import OpenSmartPenCore

final class FirstInkTests: XCTestCase {
    /// What was seen on 2026-11-16: three notebooks that do not exist, one sample each, in two
    /// seconds, while the pen wrote near the edge of a sheet.
    func testOneSampleOnUnknownPaperIsNotANotebook() {
        var ink = FirstInk()
        XCTAssertFalse(ink.isNotebook("s3/o1008/b2433"))
        XCTAssertFalse(ink.isNotebook("s3/o1009/b449"))
        XCTAssertFalse(ink.isNotebook("s11/o892/b3021"))
    }

    func testARunOfSamplesOnTheSamePaperIsANotebook() {
        var ink = FirstInk()
        for _ in 1..<FirstInk.samplesNeeded { XCTAssertFalse(ink.isNotebook("s3/o27/b999")) }
        XCTAssertTrue(ink.isNotebook("s3/o27/b999"))
    }

    /// A misreading in the middle of real writing on new paper starts the count again, and the
    /// real paper still gets there.
    func testAMisreadingInTheMiddleDoesNotCountForEitherPaper() {
        var ink = FirstInk()
        for _ in 1..<FirstInk.samplesNeeded { _ = ink.isNotebook("s3/o27/b999") }
        XCTAssertFalse(ink.isNotebook("s9/o9/b9"), "one sample somewhere else")
        XCTAssertFalse(ink.isNotebook("s3/o27/b999"), "the run was broken")
        for _ in 2..<FirstInk.samplesNeeded { _ = ink.isNotebook("s3/o27/b999") }
        XCTAssertTrue(ink.isNotebook("s3/o27/b999"))
    }
}
