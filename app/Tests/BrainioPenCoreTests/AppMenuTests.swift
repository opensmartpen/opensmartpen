import AppKit
@testable import BrainioPenUI
import XCTest

/// An accessory app shows no menu bar, so nothing here is ever seen. It is still what makes ⌘C and
/// ⌘V work in a text field, which is why it is asserted rather than trusted.
final class AppMenuTests: XCTestCase {
    func testTheEditingKeysAreAllThere() {
        let items = AppMenu.editMenu().items.filter { !$0.isSeparatorItem }
        let keys = Dictionary(uniqueKeysWithValues: items.map { ($0.title, $0.keyEquivalent) })
        XCTAssertEqual(keys["Select All"], "a")
        XCTAssertEqual(keys["Copy"], "c")
        XCTAssertEqual(keys["Paste"], "v")
        XCTAssertEqual(keys["Cut"], "x")
        XCTAssertEqual(keys["Undo"], "z")
        // Shift is carried by the capital letter, which is how ⇧⌘Z is spelled.
        XCTAssertEqual(keys["Redo"], "Z")
    }

    func testEveryItemGoesToWhateverHasTheKeyboard() {
        for item in AppMenu.editMenu().items where !item.isSeparatorItem {
            // A target would send the action to one fixed object; nil sends it up the responder
            // chain to the field being typed in, which is the whole point.
            XCTAssertNil(item.target, "\(item.title) must have no target")
            XCTAssertNotNil(item.action, "\(item.title) must have an action")
        }
    }

    func testInstallingGivesTheAppAnEditMenu() {
        let app = NSApplication.shared
        let before = app.mainMenu
        AppMenu.install(into: app)
        XCTAssertNotNil(app.mainMenu?.items.first(where: { $0.submenu?.title == "Edit" }))
        app.mainMenu = before
    }
}
