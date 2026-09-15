import AppKit
import BrainioPenCore
import SwiftUI

/// A window with no title bar that can still be typed into.
///
/// Borderless windows refuse key status by default, which would make the reply box look focused
/// and swallow every keystroke.
final class ActionsPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The actions, in a column down the right-hand edge of the screen.
///
/// A window of its own rather than a strip inside the viewer. What the pages ask for is not about
/// the sheet you happen to have open — an answer arrives while you are reading something else, and
/// a conversation with the agent needs more room than a margin. It sits where a person puts a
/// to-do list: at the side, out of the way of the work, always in the same place.
public final class ActionsWindowController: NSWindowController, NSWindowDelegate {
    private let store: ActionsStore
    /// Re-read while the window is open: the agent writes these files too.
    private var tick: Timer?
    public var onClose: (() -> Void)?

    public init(store: ActionsStore) {
        self.store = store
        // Borderless, with the header drawn inside it. A title bar here is a strip of chrome above
        // a heading that says the same word, and its buttons — minimise, zoom — mean nothing to a
        // column docked against the edge of a screen. What the title bar was providing is kept: the
        // window is dragged by its background, and closed by a button in the header.
        let panel = ActionsPanelWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
                                       styleMask: [.borderless, .resizable],
                                       backing: .buffered, defer: false)
        panel.title = "Actions"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 300)
        // Rounded on the left, square against the screen edge it is docked to.
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        super.init(window: panel)
        panel.contentView = NSHostingView(rootView: ActionsView(store: store,
                                                                close: { [weak panel] in panel?.close() }))
        panel.delegate = self
        dock()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    static let width: CGFloat = 380

    /// Against the right edge, the full height the screen allows. Not resizable into a corner it
    /// was never meant to be in — though it can be dragged away, because a rule a person cannot
    /// break is a rule they end up fighting.
    private func dock() {
        guard let window, let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        window.setFrame(NSRect(x: area.maxX - Self.width, y: area.minY,
                               width: Self.width, height: area.height), display: true)
    }

    /// Show it, and put one row on screen open if somebody asked for that one.
    public func show(expanding id: String? = nil) {
        store.reload()
        if let id { store.expanded = id }
        dock()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.store.reload()
        }
    }

    public func windowWillClose(_ notification: Notification) {
        tick?.invalidate()
        tick = nil
        onClose?()
    }
}
