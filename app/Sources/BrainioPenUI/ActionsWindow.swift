import AppKit
import BrainioPenCore
import SwiftUI

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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Actions"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 300)
        panel.contentView = NSHostingView(rootView: ActionsView(store: store))
        super.init(window: panel)
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
