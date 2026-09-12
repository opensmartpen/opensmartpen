import Foundation
@testable import BrainioPenCore
import XCTest

final class ModelsTests: XCTestCase {
    let page = PageID(section: 3, owner: 27, book: 1234, page: 12)

    func testRawPath() {
        XCTAssertEqual(page.rawRelativePath, "raw/s3/o27/b1234/p12.jsonl")
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
        let line = JSONL.metaLine(captured: 5, client: "brainio-pen-mac/0.1", sdk: "NISDK3/1.1.5")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["t"] as? String, "meta")
        XCTAssertEqual(obj["captured"] as? Int, 5)
    }
}
