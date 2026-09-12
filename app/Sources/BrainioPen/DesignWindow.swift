import AppKit
import BrainioPenCore
import SwiftUI

/// A detached, always-visible copy of the panel for working on the design.
///
/// Run with `BRAINIO_PEN_DESIGN=1` and the app does nothing else: no pen, no git, no menubar item.
/// That is deliberate — it means the design window can run beside the installed LaunchAgent
/// without two processes committing to the same repo.
///
/// Both appearances are drawn side by side, because a light-only check is how a panel ends up with
/// one hard-coded colour that vanishes in dark mode. States come from `PanelModel.Scenario`:
/// several of them — a failing push, a memory drain, a first run — take real effort to provoke
/// with actual hardware, and a design pass should not depend on being able to.
final class DesignWindowController: NSWindowController, NSWindowDelegate {
    private static let scenarioKey = "design.scenario"

    private let model = PanelModel(scenario: .synced)
    private var hosts: [NSHostingController<StatusPanel>] = []
    private var picker: NSSegmentedControl!
    private var caption: NSTextField!
    private var timer: Timer?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Brainio Pen — design"
        window.isReleasedWhenClosed = false
        // Floating and on every space: the point is to keep it beside the editor while the panel
        // is being changed, not to have to go and find it.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // AppKit persists the frame under this name, so a rebuild-and-relaunch puts the window
        // back exactly where it was — which is what makes the edit loop feel like a reload.
        window.setFrameAutosaveName("brainio-pen-design")
        self.init(window: window)
        window.delegate = self
        build()

        let saved = UserDefaults.standard.string(forKey: Self.scenarioKey)
            .flatMap(PanelModel.Scenario.init(rawValue:)) ?? .synced
        select(saved)
    }

    // MARK: layout

    private func build() {
        guard let content = window?.contentView else { return }

        picker = NSSegmentedControl(labels: PanelModel.Scenario.allCases.map(\.title),
                                    trackingMode: .selectOne, target: self, action: #selector(pick))
        picker.segmentStyle = .texturedRounded

        caption = NSTextField(labelWithString: "")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .tertiaryLabelColor

        let icons = iconStrip()

        let panes = NSStackView(views: [pane(.aqua, named: "Light"), pane(.darkAqua, named: "Dark")])
        panes.orientation = .horizontal
        panes.distribution = .fillEqually
        panes.spacing = 14

        let stack = NSStackView(views: [picker, caption, panes, icons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.setCustomSpacing(16, after: caption)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    /// One appearance's copy of the panel, floated at the top of a tinted ground so it reads as a
    /// popover rather than as the window's own content.
    private func pane(_ appearance: NSAppearance.Name, named name: String) -> NSView {
        let host = NSHostingController(rootView: StatusPanel(model: model, now: Date()))
        hosts.append(host)

        let ground = NSView()
        ground.wantsLayer = true
        ground.appearance = NSAppearance(named: appearance)
        ground.layer?.backgroundColor = (appearance == .darkAqua
            ? NSColor(white: 0.09, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
        ground.layer?.cornerRadius = 10

        let label = NSTextField(labelWithString: name.uppercased())
        label.font = .systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = .tertiaryLabelColor

        for view in [label, host.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
            ground.addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: ground.topAnchor, constant: 11),
            label.leadingAnchor.constraint(equalTo: ground.leadingAnchor, constant: 13),
            host.view.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            host.view.centerXAnchor.constraint(equalTo: ground.centerXAnchor),
            // The panel sizes itself; the ground must not stretch it, only be tall enough for it.
            host.view.bottomAnchor.constraint(lessThanOrEqualTo: ground.bottomAnchor, constant: -16),
        ])
        return ground
    }

    /// The menubar mark in each of its looks, at the size it is actually seen.
    private func iconStrip() -> NSView {
        let looks: [(String, StatusIcon.Appearance)] = [
            ("rest", .init(pending: 0, battery: (72, false), working: true)),
            ("waiting", .init(pending: 2, battery: (72, false), working: true)),
            ("low", .init(pending: 0, battery: (14, true), working: true)),
            ("bt off", .init(pending: 0, battery: nil, working: false)),
        ]
        let cells: [NSView] = looks.map { name, look in
            let image = NSImageView(image: look.image)
            image.alphaValue = look.dimmed ? 0.4 : 1
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 9.5)
            label.textColor = .tertiaryLabelColor
            let cell = NSStackView(views: [image, label])
            cell.orientation = .vertical
            cell.spacing = 3
            return cell
        }
        let strip = NSStackView(views: cells)
        strip.orientation = .horizontal
        strip.spacing = 22
        return strip
    }

    // MARK: state

    @objc private func pick() {
        select(PanelModel.Scenario.allCases[picker.selectedSegment])
    }

    private func select(_ scenario: PanelModel.Scenario) {
        model.apply(scenario)
        caption.stringValue = scenario.note
        picker.selectedSegment = PanelModel.Scenario.allCases.firstIndex(of: scenario) ?? 0
        UserDefaults.standard.set(scenario.rawValue, forKey: Self.scenarioKey)
        tick()
    }

    /// `StatusPanel` takes `now` as a value, so the countdowns only move if the view is rebuilt.
    private func tick() {
        let now = Date()
        for host in hosts { host.rootView = StatusPanel(model: model, now: now) }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        // Nothing else is running in design mode, so a closed window means done.
        NSApp.terminate(nil)
    }
}

private extension StatusIcon.Appearance {
    init(pending: Int, battery: (percent: Int, low: Bool)?, working: Bool) {
        self = StatusIcon.make(pendingPages: pending, battery: battery, working: working)
    }
}
