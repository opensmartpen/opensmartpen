import Foundation
@testable import BrainioPenCore
import XCTest

/// The one secret this app holds. What matters about the file is that only its owner can read it,
/// that it survives being edited by hand, and that clearing it leaves nothing behind.
final class DamKeyTests: XCTestCase {
    var dir: URL!
    var file: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("brainio-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("dam-key")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var mode: Int? {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber)?.intValue
    }

    func testAKeyIsWrittenForItsOwnerOnly() throws {
        try DamKey.write("pk_secret", to: file)
        XCTAssertEqual(DamKey.read(at: file), "pk_secret")
        XCTAssertEqual(mode, 0o600)
    }

    func testWritingAgainKeepsThePermissions() throws {
        try DamKey.write("pk_one", to: file)
        try DamKey.write("pk_two", to: file)
        XCTAssertEqual(DamKey.read(at: file), "pk_two")
        // An atomic write replaces the file; the mode has to be put back on the new one.
        XCTAssertEqual(mode, 0o600)
    }

    func testAKeyPastedWithANewlineOrSpacesStillWorks() throws {
        try "  pk_pasted \n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(DamKey.read(at: file), "pk_pasted")
    }

    func testNoFileAndAnEmptyFileBothMeanNoKey() throws {
        XCTAssertNil(DamKey.read(at: file))
        try "\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(DamKey.read(at: file))
    }

    func testClearingTheKeyRemovesTheFile() throws {
        try DamKey.write("pk_secret", to: file)
        try DamKey.write(nil, to: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(DamKey.read(at: file))
    }

    /// A loosened file is still read — the person may have meant it — and the log says so.
    func testALooseFileIsReadRatherThanRefused() throws {
        try DamKey.write("pk_secret", to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(DamKey.read(at: file), "pk_secret")
    }

    func testTheKeyLivesBesideTheConfigNotInsideIt() {
        XCTAssertEqual(DamKey.location.lastPathComponent, "dam-key")
        XCTAssertEqual(DamKey.location.deletingLastPathComponent(),
                       Config.defaultLocation.deletingLastPathComponent())
    }
}
