import XCTest
@testable import OpenSmartPenUI

final class BluetoothRefusedTests: XCTestCase {
    /// "Off" and "not allowed" need opposite fixes. A person told "off" switches the radio off and
    /// on, which never helps when the cause is a permission.
    func testTheTooltipNamesTheCauseItIs() {
        let off = StatusIcon.make(pendingPages: 0, battery: nil, working: false, connected: false)
        XCTAssertEqual(off.tooltip, "Open Smart Pen — Bluetooth is off")
        let refused = StatusIcon.make(pendingPages: 0, battery: nil, working: false, connected: false, refused: true)
        XCTAssertTrue(refused.tooltip.contains("not allowed to use Bluetooth"))
    }

    /// The link is to one page of System Settings, and macOS takes it only in this form.
    func testTheButtonLeadsToTheBluetoothPageOfSystemSettings() {
        XCTAssertEqual(PanelModel.bluetoothSettings.scheme, "x-apple.systempreferences")
        XCTAssertEqual(PanelModel.bluetoothSettings.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
    }

    func testAPanelShownAsRefusedSaysSo() {
        var snapshot = PanelModel.Snapshot()
        snapshot.bluetoothRefused = true
        XCTAssertTrue(PanelModel(snapshot: snapshot).bluetoothRefused)
        XCTAssertFalse(PanelModel(snapshot: PanelModel.Snapshot()).bluetoothRefused)
    }
}
