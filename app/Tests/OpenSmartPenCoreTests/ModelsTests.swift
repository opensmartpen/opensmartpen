import Foundation
@testable import OpenSmartPenCore
import XCTest

final class ModelsTests: XCTestCase {
    let page = PageID(section: 3, owner: 27, book: 1234, page: 12)

    func testAPageNamesItsProductButNotItsCopy() {
        // A page knows which product it is a sheet of. Which *copy* holds it is the folder's
        // business, so the path is not derivable from the page alone (ADR-002).
        XCTAssertEqual(page.surface, "s3/o27/b1234")
        XCTAssertEqual(page.description, "s3/o27/b1234/p12")
        XCTAssertEqual(PageID(surface: "s3/o27/b1234", page: 12), page)
        XCTAssertNil(PageID(surface: "a canvas", page: 1), "another client brings another form")
    }

    func testStrokeLineIsValidJSONWithExpectedShape() throws {
        let s = Stroke(id: UUID(uuidString: "0B1C2D3E-4F50-6172-8394-A5B6C7D8E9F0")!, page: page, start: 1000, end: 1020,
                       dots: [DotSample(x: 12.34, y: 56.7, force: 0.5, dt: 0, tiltX: 90, tiltY: 88, twist: 3),
                              DotSample(x: 12.4, y: 56.75, force: 0.625, dt: 8)],
                       source: .live, penMac: "AA:BB", firmware: "1.03")
        let line = JSONL.strokeLine(s)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["t"] as? String, "stroke")
        XCTAssertEqual(obj["id"] as? String, "0b1c2d3e-4f50-6172-8394-a5b6c7d8e9f0")
        XCTAssertEqual(obj["start"] as? Int, 1000)
        XCTAssertEqual(obj["end"] as? Int, 1020)
        XCTAssertEqual(obj["src"] as? String, "live")
        XCTAssertEqual(obj["client"] as? String, "pen", "every event says which client produced it")
        XCTAssertEqual(obj["pen"] as? String, "AA:BB")
        let dots = try XCTUnwrap(obj["dots"] as? [[Any]])
        XCTAssertEqual(dots.count, 2)
        XCTAssertEqual(dots[0][0] as? Double, 12.34)
        XCTAssertEqual(dots[0][2] as? Double, 0.5)
        XCTAssertEqual(dots[0][4] as? Int, 90)
        XCTAssertTrue(dots[1][4] is NSNull)
        XCTAssertEqual(dots[1][3] as? Int, 8)
        XCTAssertFalse(line.contains("\n"))
    }

    func testNumberFormattingIsCompact() {
        XCTAssertEqual(JSONL.fmt(12.0, 2), "12")
        XCTAssertEqual(JSONL.fmt(12.30, 2), "12.3")
        XCTAssertEqual(JSONL.fmt(0.125, 3), "0.125")
        XCTAssertEqual(JSONL.fmt(0, 3), "0")
    }

    func testMetaLine() throws {
        let line = JSONL.metaLine(captured: 5, app: "opensmartpen-mac/0.1", sdk: "NISDK3/1.1.5")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["t"] as? String, "meta")
        XCTAssertEqual(obj["captured"] as? Int, 5)
        XCTAssertEqual(obj["v"] as? Int, JSONL.formatVersion)
        XCTAssertEqual(obj["app"] as? String, "opensmartpen-mac/0.1")
        XCTAssertNil(obj["client"], "the header names the build that wrote the file, not a client")
    }
}
