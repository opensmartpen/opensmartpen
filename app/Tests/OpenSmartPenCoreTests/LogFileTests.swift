import XCTest
@testable import OpenSmartPenCore

final class LogFileTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("logfile-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? -1
    }

    func testMakesTheFolderAndAddsToTheEnd() throws {
        let url = folder.appendingPathComponent("deep/app.log")
        LogFile(url: url).append(Data("one\n".utf8))
        // A second start of the app adds to what is there.
        LogFile(url: url).append(Data("two\n".utf8))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\ntwo\n")
    }

    func testAFullFileIsPutAsideAndTheLogStaysUnderTwoTimesTheLimit() throws {
        let url = folder.appendingPathComponent("app.log")
        let log = LogFile(url: url, limit: 100)
        XCTAssertEqual(log.previousURL.lastPathComponent, "app.1.log")
        let line = Data(String(repeating: "x", count: 29).appending("\n").utf8)
        for _ in 0..<50 { log.append(line) }
        XCTAssertLessThanOrEqual(size(url), 100)
        XCTAssertLessThanOrEqual(size(log.previousURL), 100)
        XCTAssertGreaterThan(size(log.previousURL), 0)
        // No third file: the one before the last is gone.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
    }
}
