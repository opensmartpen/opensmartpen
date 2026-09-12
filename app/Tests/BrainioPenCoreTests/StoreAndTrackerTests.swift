import Foundation
@testable import BrainioPenCore
import XCTest

final class StoreAndTrackerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brainio-pen-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
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

    /// The rename must not cost the paired pen. A PenBridge-era config directory is adopted whole,
    /// because `pen-state.json` sits beside `config.json` and half of it is not worth having.
    func testLegacyConfigDirectoryIsAdopted() throws {
        let old = root.appendingPathComponent("penbridge")
        let new = root.appendingPathComponent("brainio-pen")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        var saved = Config()
        saved.penMac = "9c7bd24833d9"
        saved.lowBatteryPercent = 15
        try saved.save(to: old.appendingPathComponent("config.json"))
        try Data("{\"9c7bd24833d9\":{}}".utf8).write(to: old.appendingPathComponent("pen-state.json"))

        XCTAssertTrue(Config.adoptLegacyDirectory(at: new.appendingPathComponent("config.json"),
                                                  legacy: old.appendingPathComponent("config.json")))
        XCTAssertEqual(try Config.loadOrCreate(at: new.appendingPathComponent("config.json")), saved,
                       "the paired pen and edited thresholds survive the rename")
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent("pen-state.json").path),
                      "pen-state.json travels with it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("config.json").path),
                      "the old directory is copied, not emptied, so an install still on the old name keeps working")
    }

    func testLegacyConfigIsNotAdoptedOverAnExistingOne() throws {
        let old = root.appendingPathComponent("penbridge")
        let new = root.appendingPathComponent("brainio-pen")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        var legacy = Config()
        legacy.quietMinutes = 99
        try legacy.save(to: old.appendingPathComponent("config.json"))
        var mine = Config()
        mine.quietMinutes = 3
        try mine.save(to: new.appendingPathComponent("config.json"))

        XCTAssertFalse(Config.adoptLegacyDirectory(at: new.appendingPathComponent("config.json"),
                                                   legacy: old.appendingPathComponent("config.json")))
        XCTAssertEqual(try Config.loadOrCreate(at: new.appendingPathComponent("config.json")).quietMinutes, 3)
    }

    /// The two real locations, spelled out. Every other test here passes explicit paths, so a typo
    /// in either directory name would otherwise pass the whole suite and only show up as a lost
    /// pairing on someone's Mac.
    func testRealConfigLocationsAreNamedCorrectly() {
        setenv("XDG_CONFIG_HOME", root.path, 1)
        defer { unsetenv("XDG_CONFIG_HOME") }
        XCTAssertEqual(Config.defaultLocation, root.appendingPathComponent("brainio-pen/config.json"))
        XCTAssertEqual(Config.legacyLocation, root.appendingPathComponent("penbridge/config.json"))
    }

    /// The whole point, end to end: a PenBridge install's config, found where it really lives, is
    /// what `loadOrCreate()` returns on the first launch under the new name.
    func testFirstLaunchAdoptsTheRealLegacyLocation() throws {
        setenv("XDG_CONFIG_HOME", root.path, 1)
        defer { unsetenv("XDG_CONFIG_HOME") }
        var old = Config()
        old.penMac = "9c7bd24833d9"
        old.deleteFromPenAfterPublish = false
        try old.save(to: Config.legacyLocation)

        XCTAssertEqual(try Config.loadOrCreate(), old)
    }

    /// Adoption reaches into the home directory, so it must only ever fire for the real location.
    /// A test or a second profile pointing `loadOrCreate` elsewhere gets defaults, not someone
    /// else's paired pen.
    func testLoadOrCreateAtACustomPathNeverAdopts() throws {
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
