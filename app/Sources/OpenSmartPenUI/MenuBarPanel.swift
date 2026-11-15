import AppKit
import SwiftUI

/// The panel, hung under the menubar the way macOS hangs its own.
///
/// `NSPopover` was the obvious thing and it is the wrong thing: it always draws a callout arrow,
/// and it centres itself on the item it comes from. Neither is what the system does — open Battery
/// or Wi-Fi and the panel is a plain rounded rectangle whose left edge lines up with the icon.
/// A popover reads as a document affordance; this reads as part of the menubar.
public final class MenuBarPanel: NSPanel {
    /// Distance below the menubar, matching the system's own gap.
    private static let gap: CGFloat = 6
    /// Never closer than this to the edge of the screen.
    private static let margin: CGFloat = 8

    private static let radius: CGFloat = 10

    /// A rounded rectangle that stretches from its middle, so one small image fits any size.
    private static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private var outsideClick: Any?
    private var onClose: (() -> Void)?

    public init(content: NSViewController) {
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
        // A mask image, not a rounded layer. The material is drawn by the window server behind
        // the window, where a layer's corner radius does not reach: the layer clips the content
        // and leaves a few pixels of unclipped material showing in each corner. The mask is what
        // the window server itself cuts the material, and the shadow, to.
        blur.maskImage = Self.mask(radius: Self.radius)

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

    public override var canBecomeKey: Bool { true }

    /// Show under a status item, left edges aligned — not centred, which is the popover behaviour
    /// and not the system's.
    public func show(under button: NSStatusBarButton, onClose: @escaping () -> Void) {
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
        // The shadow is cut to the window's shape when it is first drawn, and kept. A panel that
        // has changed size since then would otherwise wear the outline of the size it was.
        invalidateShadow()
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

    public func dismiss() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
        orderOut(nil)
        onClose?()
    }

    /// True while something the panel itself opened has the keyboard focus, such as a menu at
    /// the mouse. The panel then stays where it is, so what opened reads as part of it.
    public var staysOpen = false

    public override func resignKey() {
        super.resignKey()
        if !staysOpen { dismiss() }
    }

    /// Escape closes it, as it closes a menu.
    public override func cancelOperation(_ sender: Any?) { dismiss() }

    /// The footer advertises ⌘, and ⌘Q, so they have to work. A borderless panel has no menu bar
    /// of its own to route them through.
    public var onCommand: ((String) -> Bool)?

    public override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           let key = event.charactersIgnoringModifiers,
           onCommand?(key) == true { return }
        super.keyDown(with: event)
    }

    /// Re-measure after the content changes height — a page arriving, a countdown ending — keeping
    /// the top edge still so the panel grows downward rather than jumping.
    public func resizeToContent() {
        guard isVisible, let content = contentView?.subviews.first else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard size.width > 0, size.height > 0, size != frame.size else { return }
        let top = frame.maxY
        setContentSize(size)
        setFrameOrigin(NSPoint(x: frame.minX, y: top - size.height))
        invalidateShadow()
    }
}
