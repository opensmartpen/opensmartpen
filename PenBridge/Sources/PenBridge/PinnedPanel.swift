import AppKit
import SwiftUI

/// The panel itself, kept in a window instead of in the popover.
///
/// Same model, same view — only the container changes. The popover closes when you click away,
/// which makes it useless for watching the panel change while you write or while the code is
/// rebuilt. This window stays above other windows and on every space.
final class PinnedPanelController: NSWindowController, NSWindowDelegate {
    private let model: PanelModel
    private let host: NSHostingController<StatusPanel>
    /// Told when the user closes the window, so the panel can show "Pin" again.
    var onClose: (() -> Void)?

    init(model: PanelModel, now: Date) {
        self.model = model
        host = NSHostingController(rootView: StatusPanel(model: model, now: now))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "PenBridge"
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        // AppKit puts the window back where you left it after a restart.
        window.setFrameAutosaveName("penbridge-pinned")
        super.init(window: window)
        window.delegate = self
        fit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// `StatusPanel` takes `now` as a value, so the countdowns only move if the view is rebuilt.
    func render(now: Date) {
        host.rootView = StatusPanel(model: model, now: now)
        fit()
    }

    /// The panel is 300 wide and any height. The window follows the content instead of the
    /// content stretching to the window, and it grows from the top so the title bar does not move.
    private func fit() {
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        guard size.width > 0, size.height > 0, let window else { return }
        guard window.contentLayoutRect.size != size else { return }
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
