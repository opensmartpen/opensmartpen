import XCTest
@testable import OpenSmartPenCore

final class AppLocationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")

    private func location(_ path: String) -> AppLocation {
        AppLocation(bundle: URL(fileURLWithPath: path), home: home)
    }

    func testWhereTheAppIsDecidesIfTheMoveIsOffered() {
        XCTAssertEqual(location("/Applications/Open Smart Pen.app"), .applications)
        XCTAssertEqual(location("/Users/someone/Applications/Open Smart Pen.app"), .applications)
        XCTAssertEqual(location("/Volumes/Open Smart Pen/Open Smart Pen.app"), .diskImage)
        XCTAssertEqual(location("/private/var/folders/91/x/T/AppTranslocation/6B1F/d/Open Smart Pen.app"), .translocated)
        XCTAssertEqual(location("/Users/someone/Downloads/Open Smart Pen.app"), .downloads)
        XCTAssertEqual(location("/Users/someone/git/app/dist/Open Smart Pen.app"), .elsewhere)
        XCTAssertEqual(location("/Users/someone/git/app/.build/debug/opensmartpen"), .notABundle)

        XCTAssertFalse(location("/Applications/Open Smart Pen.app").offersMove)
        XCTAssertTrue(location("/Volumes/Open Smart Pen/Open Smart Pen.app").cannotStay)
        XCTAssertTrue(location("/Users/someone/Downloads/Open Smart Pen.app").offersMove)
        XCTAssertFalse(location("/Users/someone/Downloads/Open Smart Pen.app").cannotStay)
        XCTAssertFalse(location("/Users/someone/git/app/dist/Open Smart Pen.app").offersMove,
                       "a place somebody chose is left alone")
        XCTAssertFalse(location("/Applications-old/Open Smart Pen.app") == .applications)
    }

    func testTheAppGoesToThePersonsOwnFolderWhenTheSharedOneIsClosed() {
        XCTAssertEqual(AppMover.destination(name: "A.app", home: home, systemWritable: true).path, "/Applications/A.app")
        XCTAssertEqual(AppMover.destination(name: "A.app", home: home, systemWritable: false).path,
                       "/Users/someone/Applications/A.app")
    }

    func testAnOlderCopyIsReplacedAndNothingIsLeftBeside() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("image/A.app")
        let destination = root.appendingPathComponent("Applications/A.app")
        for (folder, text) in [(source, "new"), (destination, "old")] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: folder.appendingPathComponent("Contents/version"))
        }
        try AppMover.install(from: source, to: destination)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Contents/version"), encoding: .utf8), "new")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["A.app"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the copy on the disk image is not touched")
    }

    func testACopyThatFailsLeavesTheOldApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Applications/A.app")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("version"))
        XCTAssertThrowsError(try AppMover.install(from: root.appendingPathComponent("missing/A.app"), to: destination))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("version"), encoding: .utf8), "old")
    }
}
