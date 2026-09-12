import AppKit
import SwiftUI

/// The panel, hung under the menubar the way macOS hangs its own.
///
/// `NSPopover` was the obvious thing and it is the wrong thing: it always draws a callout arrow,
/// and it centres itself on the item it comes from. Neither is what the system does — open Battery
/// or Wi-Fi and the panel is a plain rounded rectangle whose left edge lines up with the icon.
/// A popover reads as a document affordance; this reads as part of the menubar.
final class MenuBarPanel: NSPanel {
    /// Distance below the menubar, matching the system's own gap.
    private static let gap: CGFloat = 6
    /// Never closer than this to the edge of the screen.
    private static let margin: CGFloat = 8

    private var outsideClick: Any?
    private var onClose: (() -> Void)?

    init(content: NSViewController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        // Above full-screen apps, and it must not take the active space with it.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .utilityWindow

        let blur = NSVisualEffectView()
        blur.material = .menu
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true

        let view = content.view
        view.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: blur.topAnchor),
            view.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        contentView = blur
    }

    override var canBecomeKey: Bool { true }

    /// Show under a status item, left edges aligned — not centred, which is the popover behaviour
    /// and not the system's.
    func show(under button: NSStatusBarButton, onClose: @escaping () -> Void) {
        self.onClose = onClose

        guard let content = contentView?.subviews.first else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        setContentSize(size)

        guard let buttonWindow = button.window else { return }
        let onScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        var x = onScreen.minX
        if let visible = screen?.visibleFrame {
            // Slide back onto the screen for an item near the right edge, which is where a
            // menubar item usually is.
            x = min(x, visible.maxX - size.width - Self.margin)
            x = max(x, visible.minX + Self.margin)
        }
        setFrameOrigin(NSPoint(x: x, y: onScreen.minY - size.height - Self.gap))

        orderFrontRegardless()
        makeKey()
        watchForOutsideClick()
    }

    /// A click anywhere else dismisses it, which is what every menubar panel does and what a
    /// borderless window does not do on its own.
    private func watchForOutsideClick() {
        guard outsideClick == nil else { return }
        outsideClick = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
        orderOut(nil)
        onClose?()
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    /// Escape closes it, as it closes a menu.
    override func cancelOperation(_ sender: Any?) { dismiss() }

    /// The footer advertises ⌘, and ⌘Q, so they have to work. A borderless panel has no menu bar
    /// of its own to route them through.
    var onCommand: ((String) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           let key = event.charactersIgnoringModifiers,
           onCommand?(key) == true { return }
        super.keyDown(with: event)
    }

    /// Re-measure after the content changes height — a page arriving, a countdown ending — keeping
    /// the top edge still so the panel grows downward rather than jumping.
    func resizeToContent() {
        guard isVisible, let content = contentView?.subviews.first else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard size.width > 0, size.height > 0, size != frame.size else { return }
        let top = frame.maxY
        setContentSize(size)
        setFrameOrigin(NSPoint(x: frame.minX, y: top - size.height))
    }
}
