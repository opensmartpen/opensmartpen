import Foundation
@testable import OpenSmartPenCore
import XCTest

final class StoreAndTrackerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("opensmartpen-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A copy to file strokes into. The id is fixed here so a failure names the same folder twice.
    let folder = BookFolder(surface: "s3/o27/b5", id: "7f3a9c")

    func ref(_ page: PageID, in folder: BookFolder? = nil) -> PageRef {
        PageRef(folder: folder ?? BookFolder(surface: page.surface, id: "7f3a9c"), page: page)
    }

    /// Each stroke gets its own geometry, derived from `start`, so distinct strokes never look
    /// like duplicates of one another (see RawStore's duplicate rejection).
    func stroke(_ page: PageID, start: Int) -> Stroke {
        let x = Double(start % 1000)
        return Stroke(page: page, start: start, end: start + 10,
               dots: [DotSample(x: x, y: 2, force: 0.3, dt: 0), DotSample(x: x + 0.5, y: 2.5, force: 0.4, dt: 12)],
               source: .live, penMac: "M", firmware: "F")
    }

    func testAppendCreatesMetaThenAppends() throws {
        let store = RawStore(root: root, app: "c", sdk: "s")
        let page = PageID(section: 3, owner: 27, book: 5, page: 7)
        let touched = try store.append([stroke(page, start: 20), stroke(page, start: 10)], to: folder)
        XCTAssertEqual(touched, [ref(page)])
        try store.append([stroke(page, start: 30)], to: folder)
        let text = try String(contentsOf: store.fileURL(for: ref(page)), encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].hasPrefix("{\"t\":\"meta\""))
        XCTAssertTrue(lines[1].contains("\"start\":10"), "strokes within one append are sorted by start")
        XCTAssertTrue(lines[2].contains("\"start\":20"))
        XCTAssertTrue(lines[3].contains("\"start\":30"))
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    /// A process killed in mid-write leaves a line with no newline on the end. The next stroke
    /// must not be written onto that line: one interruption costs one record, never two.
    func testAWriteInterruptedMidLineCostsOnlyThatLine() throws {
        let store = RawStore(root: root, app: "c", sdk: "s")
        let page = PageID(section: 3, owner: 27, book: 5, page: 7)
        try store.append([stroke(page, start: 10)], to: folder)
        let url = store.fileURL(for: ref(page))
        try (String(contentsOf: url, encoding: .utf8) + "{\"t\":\"stro").write(to: url, atomically: true, encoding: .utf8)

        try store.append([stroke(page, start: 20)], to: folder)

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[2], "{\"t\":\"stro", "the broken line stays as it is; the record is never rewritten")
        let recovered = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[3].utf8)) as? [String: Any])
        XCTAssertEqual(recovered["start"] as? Int, 20, "the stroke after the break is readable on its own")
    }

    func testAppendGroupsByPage() throws {
        let store = RawStore(root: root, app: "c", sdk: "s")
        let a = PageID(section: 3, owner: 27, book: 5, page: 1)
        let b = PageID(section: 3, owner: 27, book: 5, page: 2)
        let touched = try store.append([stroke(a, start: 1), stroke(b, start: 2)], to: folder)
        XCTAssertEqual(touched, [ref(a), ref(b)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: ref(a)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: ref(b)).path))
    }

    func testQuietTracker() {
        let t = QuietTracker()
        let a = ref(PageID(section: 3, owner: 27, book: 5, page: 1))
        let b = ref(PageID(section: 3, owner: 27, book: 5, page: 2))
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
        let a = ref(PageID(section: 3, owner: 27, book: 5, page: 1))
        let b = ref(PageID(section: 3, owner: 27, book: 5, page: 2))
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
        edited.pairedPens = [PairedPen(mac: "9C:7B:D2:00:00:01")]
        edited.quietSeconds = 45
        edited.s3.bucket = "notes"
        edited.s3.accessKeyId = "AKIAEXAMPLE"
        try edited.save(to: url)
        XCTAssertEqual(try Config.loadOrCreate(at: url), edited)
        // A partial file (older version, hand-edited) still loads: missing keys take defaults.
        try Data("{\"quietSeconds\": 15}".utf8).write(to: url)
        XCTAssertEqual(try Config.loadOrCreate(at: url).quietSeconds, 15)
        XCTAssertTrue(try Config.loadOrCreate(at: url).s3.isEmpty)
        // A file from before the bucket still loads, and keys the app no longer has are dropped.
        try Data("{\"quietMinutes\": 10, \"gitPush\": true, \"agentHost\": \"https://agents.example.com\"}".utf8)
            .write(to: url)
        XCTAssertEqual(try Config.loadOrCreate(at: url), Config())
    }

    /// A pen says its address in the open, so another device can say it too. A pen that has
    /// connected before is known by what macOS calls it, and the address alone is not enough.
    func testADeviceThatOnlySaysThePensAddressIsNotThePen() {
        var config = Config()
        config.pairedPens = [PairedPen(mac: "9c7bd24833d9", peripheralId: "P-1")]
        XCTAssertTrue(config.isPaired(mac: "9c7bd24833d9", peripheralId: "P-1"))
        XCTAssertFalse(config.isPaired(mac: "9c7bd24833d9", peripheralId: "P-2"), "a copy of the address")
        XCTAssertFalse(config.isPaired(mac: "9c7bd24833d9", peripheralId: nil))
        XCTAssertFalse(config.isPaired(mac: "aabbccddeeff", peripheralId: "P-1"), "the pen does not change its address")
        XCTAssertTrue(config.saysThePenOfAnother(mac: "9C:7B:D2:48:33:D9", peripheralId: "P-2"))
        XCTAssertFalse(config.saysThePenOfAnother(mac: "9c7bd24833d9", peripheralId: "P-1"))
        XCTAssertFalse(config.saysThePenOfAnother(mac: "aabbccddeeff", peripheralId: "P-2"), "a stranger")

        // A pen that has not connected yet has only its address, and the first connection fills in the rest.
        config.pairedPens = [PairedPen(mac: "9c7bd24833d9")]
        XCTAssertTrue(config.isPaired(mac: "9c7bd24833d9", peripheralId: "P-9"))
        XCTAssertFalse(config.saysThePenOfAnother(mac: "9c7bd24833d9", peripheralId: "P-9"))
    }

    /// A config from before pens were a list names one pen. It must come back as a list of one,
    /// or upgrading unpairs the pen somebody is writing with.
    func testSinglePairedPenIsReadIntoTheList() throws {
        let url = root.appendingPathComponent("config.json")
        try Data("{\"penMac\": \"9C:7B:D2:48:33:D9\", \"penPeripheralId\": \"P-1\"}".utf8).write(to: url)
        let config = try Config.loadOrCreate(at: url)
        XCTAssertEqual(config.pairedPens, [PairedPen(mac: "9c7bd24833d9", peripheralId: "P-1")])
        XCTAssertTrue(config.isPaired(mac: "9c:7b:d2:48:33:d9", peripheralId: "P-1"))
        XCTAssertTrue(config.isPaired(mac: "", peripheralId: "P-1"))
        XCTAssertFalse(config.isPaired(mac: "aabbccddeeff", peripheralId: "P-2"))

        // Written back as the list only, so the old keys do not linger and disagree with it.
        try config.save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("penMac"))
        XCTAssertEqual(try Config.loadOrCreate(at: url).pairedPens, config.pairedPens)
    }

    /// The real location, spelled out. Every other test here passes explicit paths, so a typo in
    /// the directory name would otherwise pass the whole suite.
    func testRealConfigLocationIsNamedCorrectly() {
        setenv("XDG_CONFIG_HOME", root.path, 1)
        defer { unsetenv("XDG_CONFIG_HOME") }
        XCTAssertEqual(Config.defaultLocation, root.appendingPathComponent("opensmartpen/config.json"))
    }

    /// A path with no file gets the defaults.
    func testLoadOrCreateAtACustomPathGivesDefaults() throws {
        let url = root.appendingPathComponent("elsewhere/config.json")
        XCTAssertEqual(try Config.loadOrCreate(at: url), Config())
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
        let store = RawStore(root: root, app: "c", sdk: "s")
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

        let lamy = BookFolder(surface: page.surface, id: "2b81e4")
        XCTAssertEqual(try store.append([live], to: lamy), [ref(page, in: lamy)])
        XCTAssertEqual(try store.append([offline], to: lamy), [], "duplicate contributes no touched page")
        XCTAssertEqual(try store.append([other], to: lamy), [ref(page, in: lamy)])
        let file = store.fileURL(for: ref(page, in: lamy))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count, 3,
                       "meta + 2 strokes")

        // A fresh store instance re-reads signatures from disk (restart safety).
        let again = RawStore(root: root, app: "c", sdk: "s")
        XCTAssertEqual(try again.append([offline], to: lamy), [])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count, 3)
    }
}
