import Foundation
@testable import PenBridgeCore
import XCTest

final class StoreAndTrackerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("penbridge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func stroke(_ page: PageID, start: Int) -> Stroke {
        Stroke(page: page, start: start, end: start + 10, dots: [DotSample(x: 1, y: 2, force: 0.3, dt: 0)],
               source: .live, penMac: "M", firmware: "F")
    }

    func testAppendCreatesMetaThenAppends() throws {
        let store = RawStore(root: root, client: "c", sdk: "s")
        let page = PageID(section: 3, owner: 27, book: 5, page: 7)
        let touched = try store.append([stroke(page, start: 20), stroke(page, start: 10)])
        XCTAssertEqual(touched, [page])
        try store.append([stroke(page, start: 30)])
        let text = try String(contentsOf: store.fileURL(for: page), encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].hasPrefix("{\"t\":\"meta\""))
        XCTAssertTrue(lines[1].contains("\"start\":10"), "strokes within one append are sorted by start")
        XCTAssertTrue(lines[2].contains("\"start\":20"))
        XCTAssertTrue(lines[3].contains("\"start\":30"))
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testAppendGroupsByPage() throws {
        let store = RawStore(root: root, client: "c", sdk: "s")
        let a = PageID(section: 3, owner: 27, book: 5, page: 1)
        let b = PageID(section: 3, owner: 27, book: 6, page: 1)
        let touched = try store.append([stroke(a, start: 1), stroke(b, start: 2)])
        XCTAssertEqual(touched, [a, b])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: a).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: b).path))
    }

    func testQuietTracker() {
        let t = QuietTracker()
        let a = PageID(section: 3, owner: 27, book: 5, page: 1)
        let b = PageID(section: 3, owner: 27, book: 5, page: 2)
        let t0 = Date(timeIntervalSince1970: 1000)
        t.touch([a], at: t0)
        t.touch([b], at: t0.addingTimeInterval(300))
        XCTAssertEqual(Set(t.quietPages(now: t0.addingTimeInterval(600), window: 600)), [a])
        XCTAssertEqual(Set(t.quietPages(now: t0.addingTimeInterval(900), window: 600)), [a, b])
        t.clear([a])
        XCTAssertEqual(t.pendingPages, [b])
    }

    func testMarkQuietDoesNotOverrideLiveActivity() {
        let t = QuietTracker()
        let a = PageID(section: 3, owner: 27, book: 5, page: 1)
        let b = PageID(section: 3, owner: 27, book: 5, page: 2)
        let now = Date()
        t.touch([a], at: now)
        t.markQuiet([a, b])
        XCTAssertEqual(t.quietPages(now: now, window: 600), [b])
    }

    func testConfigRoundTripAndDefaults() throws {
        let url = root.appendingPathComponent("config.json")
        let created = try Config.loadOrCreate(at: url)
        XCTAssertEqual(created, Config())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        var edited = created
        edited.penMac = "9C:7B:D2:00:00:01"
        edited.quietMinutes = 3
        try edited.save(to: url)
        XCTAssertEqual(try Config.loadOrCreate(at: url), edited)
        // A partial file (older version, hand-edited) still loads: missing keys take defaults.
        try Data("{\"quietMinutes\": 1}".utf8).write(to: url)
        XCTAssertEqual(try Config.loadOrCreate(at: url).quietMinutes, 1)
        XCTAssertEqual(try Config.loadOrCreate(at: url).gitPush, true)
    }

    func testDedupingNotifier() {
        var now = Date(timeIntervalSince1970: 0)
        let rec = RecordingNotifier()
        let d = DedupingNotifier(rec, window: 60, now: { now })
        d.post(Notice(key: "k", title: "a", body: ""))
        d.post(Notice(key: "k", title: "b", body: ""))
        XCTAssertEqual(rec.notices.count, 1)
        now = now.addingTimeInterval(61)
        d.post(Notice(key: "k", title: "c", body: ""))
        XCTAssertEqual(rec.notices.count, 2)
        d.reset("k")
        d.post(Notice(key: "k", title: "d", body: ""))
        XCTAssertEqual(rec.notices.count, 3)
    }

    func testDuplicateStrokeAcrossSourcesIsDropped() throws {
        let store = RawStore(root: root, client: "c", sdk: "s")
        let page = PageID(section: 3, owner: 1012, book: 3017, page: 4)
        let dots = [DotSample(x: 19.52, y: 14.55, force: 0.862, dt: 0), DotSample(x: 20.1, y: 14.8, force: 0.5, dt: 12),
                    DotSample(x: 20.64, y: 15.04, force: 0.286, dt: 12)]
        let live = Stroke(page: page, start: 1_789_137_717_059, end: 1_789_137_717_324, dots: dots, source: .live, penMac: "M", firmware: "F")
        var offline = live
        offline.id = UUID()
        offline.start = 1_789_137_717_036 // 23 ms clock offset
        offline.end = 1_789_137_717_301
        offline.source = .offline
        var other = live
        other.id = UUID()
        other.start = live.start + 2000 // same shape drawn again later is a real stroke
        other.end = other.start + 100

        XCTAssertEqual(try store.append([live]), [page])
        XCTAssertEqual(try store.append([offline]), [], "duplicate contributes no touched page")
        XCTAssertEqual(try store.append([other]), [page])
        let lines = try String(contentsOf: store.fileURL(for: page), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3, "meta + 2 strokes")

        // A fresh store instance re-reads signatures from disk (restart safety).
        let again = RawStore(root: root, client: "c", sdk: "s")
        XCTAssertEqual(try again.append([offline]), [])
        XCTAssertEqual(try String(contentsOf: store.fileURL(for: page), encoding: .utf8).split(separator: "\n").count, 3)
    }
}
