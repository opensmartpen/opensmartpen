import AppKit
import Foundation
import PenBridgeCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let version = "0.1.0"
    static let sdkVersion = "NISDK3/1.1.5"

    private var statusItem: NSStatusItem!
    private var menu = NSMenu()
    private var config = Config()
    private let configURL = Config.defaultLocation
    private var coordinator: SyncCoordinator!
    private var session: PenSession!
    private var notifier: DedupingNotifier!
    private var tickTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.verbose = ProcessInfo.processInfo.environment["PENBRIDGE_VERBOSE"] != nil
        let base: Notifier = UserNotifier.isAvailable ? UserNotifier() : OSAScriptNotifier()
        notifier = DedupingNotifier(base)

        do {
            config = try Config.loadOrCreate(at: configURL)
        } catch {
            Log.error("config unreadable, using defaults: \(error)")
            notifier.post(Notice(key: "config", title: "PenBridge config is invalid",
                                 body: "\(configURL.path): \(error.localizedDescription). Running with defaults."))
        }
        Log.info("PenBridge \(Self.version) starting; repo \(config.repoURL.path); config \(configURL.path)")

        let publisher = GitPublisher(repo: config.repoURL, push: config.gitPush)
        do {
            let hasRemote = try publisher.ensureRepository()
            if !hasRemote && config.gitPush {
                publisher.push = false
                notifier.post(Notice(key: "no-remote", title: "Notes repo has no remote",
                                     body: "Commits are local only. Add an origin in \(config.repoURL.path) and restart PenBridge to push."))
            }
        } catch {
            Log.error("repository setup failed: \(error)")
            notifier.post(Notice(key: "repo", title: "PenBridge cannot use the notes repo",
                                 body: "\(config.repoURL.path): \(error)"))
        }

        let store = RawStore(root: config.repoURL, client: "penbridge-mac/\(Self.version)", sdk: Self.sdkVersion)
        coordinator = SyncCoordinator(store: store, tracker: QuietTracker(), publisher: publisher,
                                      notifier: notifier, quietWindow: config.quietMinutes * 60)
        coordinator.controlBooks = Set(config.controlBooks)
        coordinator.onChange = { [weak self] in self?.refreshMenu() }
        coordinator.recoverPending()

        session = PenSession(config: config, configURL: configURL, coordinator: coordinator, notifier: notifier)
        session.onChange = { [weak self] in self?.refreshMenu() }

        buildStatusItem()
        session.start()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.coordinator.tick() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("PenBridge stopping")
    }

    // MARK: menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        refreshStatusButton()
        refreshMenu()
    }

    /// Battery below the threshold turns the menubar icon red and adds the percentage, so a pen
    /// about to die is visible without opening the menu. Everything else stays a plain template icon.
    private func refreshStatusButton() {
        guard let button = statusItem.button else { return }
        let battery = session.setting.map { (pct: Int($0.battLevel), charging: $0.charging == .On) }
        let low = battery.map { $0.pct <= config.lowBatteryPercent && !$0.charging } ?? false

        if low, let battery {
            let image = NSImage(systemSymbolName: "battery.0", accessibilityDescription: "Pen battery low")?
                .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            image?.isTemplate = false
            button.image = image
            button.attributedTitle = NSAttributedString(
                string: " \(battery.pct)%",
                attributes: [.foregroundColor: NSColor.systemRed,
                             .font: NSFont.menuBarFont(ofSize: 0)])
            button.toolTip = "Pen battery \(battery.pct)% — charge it"
        } else {
            let image = NSImage(systemSymbolName: "pencil.and.scribble", accessibilityDescription: "PenBridge")
            image?.isTemplate = true
            button.image = image
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "PenBridge"
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
    }

    private func refreshMenu() {
        refreshStatusButton()
        menu.removeAllItems()
        menu.addItem(disabled(stateLine()))
        if let s = session.setting {
            menu.addItem(batteryItem(percent: Int(s.battLevel), charging: s.charging == .On))
            menu.addItem(memoryItem(percent: Int(s.memoryUsed)))
        }
        let pending = coordinator.pendingPages.count
        if pending > 0 {
            menu.addItem(disabled("\(pending) page\(pending == 1 ? "" : "s") waiting to publish"))
        }
        if let last = coordinator.lastPublish {
            let when = RelativeDateTimeFormatter().localizedString(for: last.date, relativeTo: Date())
            menu.addItem(disabled("Last publish \(when)\(last.commit.map { " (\($0))" } ?? "")"))
        }
        if let err = coordinator.lastError {
            menu.addItem(disabled("Publish failing: \(String(err.prefix(60)))"))
        }
        menu.addItem(.separator())
        menu.addItem(action("Publish now", #selector(publishNow), enabled: pending > 0 && !coordinator.isPublishing))
        menu.addItem(action(session.isPaired ? "Pair a different pen…" : "Pair pen…", #selector(pairPen)))
        menu.addItem(action("Open notes folder", #selector(openNotes)))
        menu.addItem(action("Open config file", #selector(openConfig)))
        menu.addItem(.separator())
        menu.addItem(action("Quit PenBridge", #selector(quit)))
    }

    private func stateLine() -> String {
        switch session.state {
        case .bluetoothOff: return "Bluetooth is off"
        case .scanning: return session.isPaired ? "Looking for \(session.penName.isEmpty ? "pen" : session.penName)…" : "Looking for a pen to pair…"
        case .connecting: return "Connecting to \(session.penName)…"
        case .authorizing: return "Authorising \(session.penName)…"
        case .ready: return "Connected to \(session.penName)"
        case let .draining(remaining): return "Syncing pen memory (\(remaining) book\(remaining == 1 ? "" : "s") left)…"
        }
    }

    /// A row carrying a symbol, a label and a ten-cell bar, so level is readable at a glance.
    private func gaugeItem(symbol: String, label: String, fraction: Double, tint: NSColor?) -> NSMenuItem {
        let filled = max(0, min(10, Int((fraction * 10).rounded())))
        let bar = String(repeating: "▮", count: filled) + String(repeating: "▯", count: 10 - filled)
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let text = NSMutableAttributedString(
            string: "\(label)  ",
            attributes: [.font: NSFont.menuFont(ofSize: 0),
                         .foregroundColor: tint ?? NSColor.labelColor])
        text.append(NSAttributedString(
            string: bar,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                         .foregroundColor: tint ?? NSColor.secondaryLabelColor]))
        item.attributedTitle = text
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        if let tint {
            image = image?.withSymbolConfiguration(.init(paletteColors: [tint]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        item.image = image
        item.isEnabled = false
        return item
    }

    private func batteryItem(percent: Int, charging: Bool) -> NSMenuItem {
        let symbol: String
        switch (charging, percent) {
        case (true, _): symbol = "battery.100.bolt"
        case (_, ..<13): symbol = "battery.0"
        case (_, ..<38): symbol = "battery.25"
        case (_, ..<63): symbol = "battery.50"
        case (_, ..<88): symbol = "battery.75"
        default: symbol = "battery.100"
        }
        let tint: NSColor? = charging ? .systemGreen
            : percent <= config.lowBatteryPercent ? .systemRed
            : percent <= config.lowBatteryPercent * 2 ? .systemOrange : nil
        let label = "Battery \(percent)%\(charging ? " charging" : "")"
        return gaugeItem(symbol: symbol, label: label, fraction: Double(percent) / 100, tint: tint)
    }

    private func memoryItem(percent: Int) -> NSMenuItem {
        // Pen memory is a buffer, not storage: it only fills when writing happens away from this Mac.
        let tint: NSColor? = percent >= config.memoryWarnPercent ? .systemOrange : nil
        let pages = Int((Double(percent) / 100 * 160).rounded())
        let detail = percent == 0 ? "empty" : "\(percent)% used, about \(pages) of 160 pages"
        return gaugeItem(symbol: "internaldrive", label: "Pen memory \(detail)", fraction: Double(percent) / 100, tint: tint)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func publishNow() {
        coordinator.publishAll()
    }

    @objc private func pairPen() {
        session.forgetPen()
    }

    @objc private func openNotes() {
        NSWorkspace.shared.open(config.repoURL)
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(configURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
