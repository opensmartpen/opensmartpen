import AppKit
import Foundation
import BrainioPenCore
import BrainioPenUI
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let version = "0.2.0"
    static let sdkVersion = "NISDK3/1.1.5"

    private var statusItem: NSStatusItem!
    private var panel: MenuBarPanel!
    private var panelHost: NSHostingController<StatusPanel>!
    private var config = Config()
    private let configURL = Config.defaultLocation
    private var coordinator: SyncCoordinator!
    private var session: PenSession!
    private var notifier: DedupingNotifier!
    private var model: PanelModel!
    private var books: BookRegistry!
    private var pens: PenRegistry!
    private var penState: PenState!
    private var settingsWindow: SettingsWindowController?
    /// So a new notebook is only looked up when the pen moves to a different one, rather than on
    /// every dot.
    private var lastSeenBook: String?
    private var lastSeenPage: String?
    private var viewer: Viewer!
    private var viewerWindow: ViewerWindowController?
    private var pinnedPanel: PinnedPanelController?
    private var tickTimer: Timer?
    /// Runs only while the panel is open; drives the per-page countdowns.
    private var panelTimer: Timer?
    private var panelNow = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.verbose = ProcessInfo.processInfo.environment["BRAINIO_PEN_VERBOSE"] != nil

        let base: Notifier = UserNotifier.isAvailable ? UserNotifier() : OSAScriptNotifier()
        notifier = DedupingNotifier(base)

        do {
            config = try Config.loadOrCreate(at: configURL)
        } catch {
            Log.error("config unreadable, using defaults: \(error)")
            notifier.post(Notice(key: "config", title: "Brainio Pen config is invalid",
                                 body: "\(configURL.path): \(error.localizedDescription). Running with defaults."))
        }
        Log.info("Brainio Pen \(Self.version) starting; repo \(config.repoURL.path); config \(configURL.path)")

        let publisher = GitPublisher(repo: config.repoURL, push: config.gitPush)
        do {
            let hasRemote = try publisher.ensureRepository()
            if !hasRemote && config.gitPush {
                publisher.push = false
                notifier.post(Notice(key: "no-remote", title: "Notes repo has no remote",
                                     body: "Commits are local only. Add an origin in \(config.repoURL.path) and restart Brainio Pen to push."))
            }
        } catch {
            Log.error("repository setup failed: \(error)")
            notifier.post(Notice(key: "repo", title: "Brainio Pen cannot use the notes repo",
                                 body: "\(config.repoURL.path): \(error)"))
        }

        let store = RawStore(root: config.repoURL, client: "brainio-pen-mac/\(Self.version)", sdk: Self.sdkVersion)
        coordinator = SyncCoordinator(store: store, tracker: QuietTracker(), publisher: publisher,
                                      notifier: notifier, quietWindow: config.quietMinutes * 60)
        coordinator.controlBooks = Set(config.controlBooks)
        coordinator.modeLog = ModeLog(root: config.repoURL)
        coordinator.recoverPending()

        session = PenSession(config: config, configURL: configURL, coordinator: coordinator, notifier: notifier)

        // Notebook names, page numbering and the rendered-page paths all come from books/*.json
        // in the notes repo, which the processing side also reads. One source, no drift.
        books = BookRegistry(repo: config.repoURL)
        pens = PenRegistry(repo: config.repoURL)
        penState = PenState(directory: configURL.deletingLastPathComponent())
        // The palette decides which of the strip's ten buttons mean anything. Narrowing the set is
        // an edit to one file in the repo, not a code change.
        coordinator.modeLog?.offered = Set(Palette.load(root: config.repoURL).offered)
        viewer = Viewer(books: books, repo: config.repoURL)
        // Paper we capture from but never read back. The coordinator still stores every tap in
        // raw and decodes it as a command; what stops here is everything that treats a book as a
        // notebook — a record in books/, the new-copy question, and the live page in the viewer.
        let controlBooks = Set(config.controlBooks)
        session.onDot = { [weak self] page, dot, event in
            guard let self else { return }
            guard !controlBooks.contains(page.bookKey) else { return }
            // A notebook Brainio Pen has never met gets a record the moment a page arrives from it,
            // so its pages stop being anonymous and start being rendered. Silent on purpose:
            // writing is never interrupted to ask a question.
            if lastSeenBook != page.bookKey {
                lastSeenBook = page.bookKey
                books.ensureRecord(for: page)
            }
            if lastSeenPage != page.description {
                lastSeenPage = page.description
                noteForNewNotebook(page)
            }
            viewer.receive(page: page, dot: dot, event: event)
        }
        model = PanelModel(session: session, coordinator: coordinator, config: config,
                           books: books, pens: pens, penState: penState)
        model.onShowLive = { [weak self] in self?.showViewer(nil) }
        model.onTogglePin = { [weak self] in self?.togglePinned() }
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        model.onOpenPage = { [weak self] page in self?.showViewer(page) }
        coordinator.onChange = { [weak self] in self?.stateChanged() }
        session.onChange = { [weak self] in self?.stateChanged() }

        buildStatusItem()
        model.refresh()
        refreshStatusButton()

        session.start()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.coordinator.tick()
            self?.stateChanged()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("Brainio Pen stopping")
    }

    // MARK: status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        panelHost = NSHostingController(rootView: StatusPanel(model: model, now: panelNow))
        panel = MenuBarPanel(content: panelHost)
        panel.onCommand = { [weak self] key in
            switch key {
            case ",": self?.showSettings(); return true
            // The panel no longer carries a Sync now button — the countdowns already say when it
            // happens by itself — but the lid-closing case is real, so the shortcut stays.
            case "s": self?.model.publishNow(); return true
            case "q": NSApp.terminate(nil); return true
            default: return false
            }
        }
    }

    /// Any change from the pen or the publisher lands here: recompute the panel's snapshot, then
    /// the menubar icon. Cheap enough to do on every stroke batch.
    private func stateChanged() {
        adoptPenIfNew()
        model.refresh(now: Date())
        // The pinned window has no "opened" moment to rebuild the recent list on, and a state
        // change is exactly when that list can have changed.
        if pinnedPanel != nil { model.refreshRecent() }
        refreshStatusButton()
    }

    private func refreshStatusButton() {
        guard let button = statusItem.button else { return }
        // The warning follows the flattest pen used recently, not the pen that happens to be
        // connected: with more than one pen those are different pens most of the time.
        let battery = model.lowPen.map { (percent: $0.percent, low: true) }
            ?? model.battery.map { (percent: $0.percent, low: $0.low) }
        // A dimmed icon means Brainio Pen cannot work, not that the pen is asleep: the A1 powers
        // itself off after five minutes, so a sleeping pen is the normal state and dimming for it
        // would leave the menubar permanently faint.
        let usable: Bool
        if case .bluetoothOff = model.status { usable = false } else { usable = true }
        let look = StatusIcon.make(pendingPages: model.pending.count, battery: battery, working: usable)
        button.image = look.image
        button.attributedTitle = look.title
        button.appearsDisabled = look.dimmed
        button.toolTip = look.tooltip
    }

    /// Two pads of the same model report the same Ncode id, so a fresh copy has to be noticed
    /// rather than assumed. Detection only ever asks: a wrong silent guess appends a new notebook
    /// to the old one's files and goes unnoticed for months.
    private func noteForNewNotebook(_ page: PageID) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        guard let suspicion = books.instanceWatcher.note(book: page.bookKey, page: page.page, at: now)
        else { return }
        let title = books.label(for: page).title
        Log.info("possible new notebook in \(page.bookKey): \(suspicion.reason.rawValue)")
        model.ask(suspicion, title: title)
        notifier.post(Notice(key: "new-notebook-\(page.bookKey)",
                             title: "Is this a new \(title)?",
                             body: "Confirm in Brainio Pen so its pages get their own folder."))
    }

    /// A pen that connects for the first time gets a record, so it has a name from the very first
    /// moment rather than showing as a MAC address. The name is a guess — the SDK's device name,
    /// or simply "Pen" — and the point of writing it down is that it is now yours to change.
    private func adoptPenIfNew() {
        guard session.isConnected, let mac = config.penMac, pens.record(mac: mac) == nil else { return }
        let suggested = session.penName.isEmpty ? "Pen" : session.penName
        guard let record = pens.create(mac: mac, name: suggested) else { return }
        Log.info("adopted pen \(record.mac) as \(record.name) (pens/\(record.slug).json)")
        notifier.post(Notice(key: "new-pen", title: "New pen: \(record.name)",
                             body: "Give it a name in Brainio Pen settings."))
    }

    /// Everything with a name or a number in it. The panel carries almost no words, which only
    /// works because this exists.
    private func showSettings() {
        panel?.dismiss()
        if settingsWindow == nil {
            let store = SettingsStore(pens: pens, books: books, config: config, configURL: configURL)
            store.onConfigChange = { [weak self] updated in
                guard let self else { return }
                config = updated
                coordinator.quietWindow = updated.quietMinutes * 60
                stateChanged()
            }
            settingsWindow = SettingsWindowController(store: store)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    /// The panel in its own window. The menubar panel closes on any click outside it, which makes
    /// it no use for watching the panel while you write or while the app is rebuilt.
    private func togglePinned() {
        if let pinnedPanel {
            pinnedPanel.close()          // windowWillClose does the rest
            return
        }
        let origin = panel.isVisible ? panel.frame : nil
        panel?.dismiss()
        let controller = PinnedPanelController(model: model, now: panelNow, from: origin)
        controller.onClose = { [weak self] in
            self?.pinnedPanel = nil
            self?.model.setPinned(false)
            self?.syncPanelTimer()
        }
        pinnedPanel = controller
        model.setPinned(true)
        model.refreshRecent()
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        syncPanelTimer()
    }

    /// One window for reading, whether the ink arrived a second ago or last month. Pages are
    /// drawn from raw strokes rather than opened as a PNG, so there is a single view experience
    /// and a page is readable before the pipeline has ever touched it.
    private func showViewer(_ page: PageID?) {
        panel?.dismiss()
        if viewerWindow == nil {
            viewer.attach(modeLog: coordinator.modeLog)
            viewerWindow = ViewerWindowController(viewer: viewer)
        }
        if let page { viewer.show(page: page) } else { viewer.goLatest() }
        NSApp.activate(ignoringOtherApps: true)
        viewerWindow?.showWindow(nil)
        viewerWindow?.retitle()
        viewerWindow?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: panel

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.dismiss()
            return
        }
        guard let button = statusItem.button else { return }
        session.requestSettingRefresh()
        model.refreshRecent()
        tickPanel()
        panel.show(under: button) { [weak self] in self?.syncPanelTimer() }
        syncPanelTimer()
    }

    /// One second is only worth spending while something is on screen to see it.
    private func syncPanelTimer() {
        let wanted = (panel?.isVisible ?? false) || pinnedPanel != nil
        if wanted, panelTimer == nil {
            panelTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.tickPanel()
            }
        } else if !wanted {
            panelTimer?.invalidate()
            panelTimer = nil
        }
    }

    /// Re-renders with a fresh `now`, which is what moves the countdowns.
    private func tickPanel() {
        panelNow = Date()
        model.refresh(now: panelNow)
        refreshStatusButton()
        panelHost?.rootView = StatusPanel(model: model, now: panelNow)
        panel?.resizeToContent()
        pinnedPanel?.render(now: panelNow)
    }
}
