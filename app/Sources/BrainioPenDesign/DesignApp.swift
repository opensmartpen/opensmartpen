import AppKit

/// The design app is one window and nothing else. It opens on launch and quits when the window
/// closes, because there is nothing left for it to do.
public final class DesignAppDelegate: NSObject, NSApplicationDelegate {
    private var window: DesignWindowController?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = DesignWindowController()
        window = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}
