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

    init(model: PanelModel, now: Date, from panelFrame: NSRect?) {
        self.model = model
        host = NSHostingController(rootView: StatusPanel(model: model, now: now))

        // No titlebar. A close button, a minimise button and a zoom button on a fixed-size panel
        // are three controls that either do nothing or duplicate the pin in its corner — and a
        // pinned panel should be the same object you were just looking at, not a window version
        // of it.
        let window = PinnedWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Drag it by anywhere, since there is no bar to drag it by.
        window.isMovableByWindowBackground = true

        let blur = NSVisualEffectView()
        blur.material = .menu
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true

        host.view.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: blur.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        window.contentView = blur

        super.init(window: window)
        window.delegate = self
        fit()
        // Open exactly where the panel was. Pinning is meant to feel like keeping the thing you
        // are already looking at, not like opening a second one somewhere else.
        if let panelFrame {
            window.setFrameTopLeftPoint(NSPoint(x: panelFrame.minX, y: panelFrame.maxY))
        } else {
            window.center()
        }
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
        guard window.frame.size != size else { return }
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// A borderless window still has to be able to take a click and a keystroke.
private final class PinnedWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
