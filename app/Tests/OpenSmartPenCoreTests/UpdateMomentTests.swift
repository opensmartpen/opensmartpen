import XCTest
@testable import OpenSmartPenCore

final class UpdateMomentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func moment(silentFor: TimeInterval = 3600, pending: Int = 0, publishing: Bool = false,
                        copying: Bool = false, window: Bool = false) -> UpdateMoment {
        UpdateMoment(lastPenActivity: now.addingTimeInterval(-silentFor), pendingPages: pending,
                     isPublishing: publishing, isCopyingFromPen: copying, windowIsOpen: window)
    }

    func testAnIdleAppIsQuiet() {
        XCTAssertTrue(moment().isQuiet(at: now))
    }

    func testAPenThatHasNeverWrittenIsQuiet() {
        let never = UpdateMoment(lastPenActivity: .distantPast, pendingPages: 0, isPublishing: false,
                                 isCopyingFromPen: false, windowIsOpen: false)
        XCTAssertTrue(never.isQuiet(at: now))
    }

    func testAPenThatWroteAMinuteAgoIsNotQuiet() {
        XCTAssertFalse(moment(silentFor: 60).isQuiet(at: now))
    }

    func testTheSilenceEndsExactlyAtItsLength() {
        XCTAssertFalse(moment(silentFor: UpdateMoment.silence - 1).isQuiet(at: now))
        XCTAssertTrue(moment(silentFor: UpdateMoment.silence).isQuiet(at: now))
    }

    func testAPageThatWaitsForUploadIsNotQuiet() {
        XCTAssertFalse(moment(pending: 1).isQuiet(at: now))
    }

    func testAnUploadThatRunsIsNotQuiet() {
        XCTAssertFalse(moment(publishing: true).isQuiet(at: now))
    }

    func testAPenThatIsBeingCopiedIsNotQuiet() {
        XCTAssertFalse(moment(copying: true).isQuiet(at: now))
    }

    func testAnOpenWindowIsNotQuiet() {
        XCTAssertFalse(moment(window: true).isQuiet(at: now))
    }
}
