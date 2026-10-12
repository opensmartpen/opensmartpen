import AppKit
import Foundation
import BrainioPenCore
import BrainioPenUI
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let version = "0.2.0"
    static let sdkVersion = "NISDK3/1.1.5"
    /// The build that writes a raw file, for its header line. Every raw file the app creates says
    /// this, so a file can always be traced to what made it.
    static let clientID = "brainio-pen-mac/\(version)"

    private var statusItem: NSStatusItem!
    private var panel: MenuBarPanel!
    private var panelHost: NSHostingController<StatusPanel>!
    private var config = Config()
    private let configURL = Config.defaultLocation
    private var coordinator: SyncCoordinator!
    /// Hands quiet pages to a DAM agent to be transcribed. Nil until one is configured.
    private var processor: PageProcessor?
    private var session: PenSession!
    private var notifier: DedupingNotifier!
    private var model: PanelModel!
    private var books: BookRegistry!
    private var pens: PenRegistry!
    private var penState: PenState!
    private var settingsWindow: SettingsWindowController?
    private var settingsStore: SettingsStore?
    /// So a new notebook is only looked up when the pen moves to a different one, rather than on
    /// every dot.
    private var lastSeenBook: String?
    private var viewer: Viewer!
    private var viewerWindow: ViewerWindowController?
    private var actions: ActionsStore!
    private var actionsWindow: ActionsWindowController?
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
        Log.info("Brainio Pen \(Self.version) starting; notes \(config.dataURL.path); config \(configURL.path)")

        // Notes written before ADR-002 are copied into the new layout once. The old repository is
        // left where it is, so nothing is lost if the copy turns out to be wrong.
        if let legacy = config.legacyRepoURL, legacy != config.dataURL {
            DataMigration.adoptLegacyRepo(from: legacy, to: config.dataURL)
        }

        // Git is a record of what changed, not where the notes live. Every reader goes to the
        // files themselves; a commit is there so a drain or a render can be seen as a diff.
        let publisher = GitPublisher(repo: config.dataURL, push: config.gitPush)
        do {
            let hasRemote = try publisher.ensureRepository()
            if !hasRemote && config.gitPush {
                publisher.push = false
                notifier.post(Notice(key: "no-remote", title: "Notes history has no remote",
                                     body: "Commits are local only. Add an origin in \(config.dataURL.path) and restart Brainio Pen to push."))
            }
        } catch {
            Log.error("repository setup failed: \(error)")
            notifier.post(Notice(key: "repo", title: "Brainio Pen cannot keep a history of the notes",
                                 body: "\(config.dataURL.path): \(error)"))
        }

        let store = RawStore(root: config.dataURL, app: Self.clientID, sdk: Self.sdkVersion)
        // Notebook names, page numbering and the readable-file paths all come from
        // books/<copy>/book.json, which the processing side also reads. One source, no drift.
        books = BookRegistry(root: config.dataURL)
        let router = PageRouter(books: books, store: store)
        router.adoptExisting()
        coordinator = SyncCoordinator(store: store, router: router, tracker: QuietTracker(),
                                      publisher: publisher, notifier: notifier,
                                      quietWindow: config.quietMinutes * 60)
        coordinator.controlBooks = Set(config.controlBooks)
        coordinator.modeLog = ModeLog(root: config.dataURL, app: Self.clientID, sdk: Self.sdkVersion)
        coordinator.recoverPending()

        makeProcessor()

        session = PenSession(config: config, configURL: configURL, coordinator: coordinator, notifier: notifier)

        pens = PenRegistry(repo: config.dataURL)
        penState = PenState(directory: configURL.deletingLastPathComponent())
        // The palette decides which of the strip's ten buttons mean anything. Narrowing the set is
        // an edit to one file in the repo, not a code change.
        coordinator.modeLog?.offered = Set(Palette.load(root: config.dataURL).offered)
        viewer = Viewer(books: books, repo: config.dataURL)
        // One list of what the pages ask for, read by the window that shows all of it and by the
        // menubar panel that shows the first few.
        actions = ActionsStore(books: books, root: config.dataURL)
        actions.processor = processor
        actions.roster = config.assistants
        actions.onOpenPage = { [weak self] page in self?.showViewer(page) }
        actions.onOpenSettings = { [weak self] in self?.showSettings(tab: .agents) }
        // Paper we capture from but never read back. The coordinator still stores every tap and
        // decodes it as a command; what stops here is everything that treats a book as a
        // notebook — a record of its own and the live page in the viewer.
        let controlBooks = Set(config.controlBooks)
        session.onDot = { [weak self] page, dot, event in
            guard let self else { return }
            guard !controlBooks.contains(page.surface) else { return }
            // A notebook Brainio Pen has never met gets a record the moment a page arrives from it,
            // so its pages stop being anonymous and start being rendered. Silent on purpose:
            // writing is never interrupted to ask a question.
            if lastSeenBook != page.surface {
                lastSeenBook = page.surface
                books.ensureRecord(for: page)
            }
            viewer.receive(page: page, dot: dot, event: event)
        }
        model = PanelModel(session: session, coordinator: coordinator, config: config,
                           books: books, pens: pens, penState: penState)
        model.processor = processor
        model.actionsStore = actions
        model.onShowLive = { [weak self] in self?.showViewer(nil) }
        model.onTogglePin = { [weak self] in self?.togglePinned() }
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        model.onOpenPage = { [weak self] page in self?.showViewer(page) }
        model.onOpenAction = { [weak self] id in self?.showActions(expanding: id.isEmpty ? nil : id) }
        viewer.onShowActions = { [weak self] in self?.showActions() }
        coordinator.onChange = { [weak self] in self?.stateChanged() }
        coordinator.onOfflineStored = { [weak self] pages in
            DispatchQueue.main.async { self?.viewer.reload(pages) }
        }
        session.onChange = { [weak self] in self?.stateChanged() }

        // Nothing on screen: it is what makes ⌘C and ⌘V work in the settings fields. An app with
        // no menu bar has no editing keys either, which is not obvious until somebody tries to
        // paste a key into one.
        AppMenu.install()
        buildStatusItem()

        // For working on the window itself: there is no way to click a menubar item from a script,
        // and a design pass that cannot open the thing being designed is a design pass done blind.
        if CommandLine.arguments.contains("--show-settings") { showSettings(tab: .agents) }
        if CommandLine.arguments.contains("--show-actions") {
            // Open it on something with a conversation in it, because the shut row and the open
            // row are two different designs and only one of them can be seen at a time.
            actions.reload()
            // And, when asked, with a question on it: the card that appears when DAM stops an
            // agent at the gate cannot be reached by clicking, so this is the only way to look at
            // it before shipping it.
            if CommandLine.arguments.contains("--show-approval") {
                // On an open row and a shut one, because they are two different pictures: the
                // question has to read as urgent in a list somebody is scanning, not only in the
                // conversation they happen to have open.
                let egress = ApprovalAsk(id: "rehearsal-1",
                                         kind: .egress(method: "POST", host: "slack.com",
                                                       path: "/api/chat.postMessage"),
                                         approvalId: "rehearsal-1")
                let tool = ApprovalAsk(id: "rehearsal-2", kind: .tool("Bash(git push origin main)"))
                for row in actions.items.prefix(2) {
                    actions.rehearsed[row.id] = [row.action.thread.isEmpty ? tool : egress]
                }
            }
            showActions(expanding: actions.items.first { !$0.action.thread.isEmpty }?.id)
        }
        model.refresh()
        refreshStatusButton()

        session.start()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.coordinator.tick()
            // Transcribing a page is a separate errand from committing one, and a much shorter wait, so
            // it is asked on every tick rather than only when a commit happens.
            self?.processor?.tick()
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
        settingsStore?.linkChanged()
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
        // A dimmed icon means no pen is talking to this Mac, for whatever reason — asleep, out of
        // reach, or Bluetooth off. It used to mean only the last, on the argument that the A1
        // sleeps after five minutes and a sleeping pen is the normal state. Decided 2026-09-16
        // that one rule beats two looks: dim is "not connected", and the tooltip says why.
        let usable: Bool
        if case .bluetoothOff = model.status { usable = false } else { usable = true }
        let look = StatusIcon.make(pendingPages: model.pending.count, battery: battery, working: usable,
                                   connected: session.isAnyConnected)
        button.image = look.image
        button.attributedTitle = look.title
        button.appearsDisabled = look.dimmed
        button.toolTip = look.tooltip
    }

    /// A pen that connects for the first time gets a record, so it has a name from the very first
    /// moment rather than showing as a MAC address. The name is a guess — the SDK's device name,
    /// or simply "Pen" — and the point of writing it down is that it is now yours to change.
    private func adoptPenIfNew() {
        let paired = Set(session.pairedMacs)
        for link in session.connections where link.isConnected && paired.contains(link.mac) {
            guard pens.record(mac: link.mac) == nil else { continue }
            let suggested = link.name.isEmpty ? "Pen" : link.name
            guard let record = pens.create(mac: link.mac, name: suggested) else { continue }
            Log.info("adopted pen \(record.mac) as \(record.name) (pens/\(record.slug).json)")
            notifier.post(Notice(key: "new-pen-\(record.mac)", title: "New pen: \(record.name)",
                                 body: "Give it a name in Brainio Pen settings."))
            settingsStore?.reload()
        }
    }

    /// Wire up page transcription, or leave it off.
    ///
    /// All three of host, agent and key are needed, and the key is in a file of its own, so a
    /// config carried to another Mac starts with transcription off rather than with a broken connection.
    /// Nothing else changes when it is off: pages are captured and committed exactly as before.
    ///
    /// Read straight through, on the main thread. While the key was in the Keychain this ran on a
    /// background queue, because that read could stop and wait for a person to answer a dialog —
    /// and one launch did, for forty minutes. Reading a file cannot.
    private func makeProcessor() {
        processor = nil
        guard let account = config.damAccount() else {
            Log.info("no DAM agent configured; pages are captured but not transcribed")
            return
        }
        do {
            // One key, several agents. The transcriber is the account above; anything routed elsewhere
            // gets its own connection out of the same key.
            let fleet = try DamAgents(transcriber: account)
            let imager = PageImager(books: books, root: config.dataURL, modeLog: coordinator.modeLog)
            let processor = PageProcessor(books: books, root: config.dataURL, imaging: imager,
                                          fleet: fleet, notifier: notifier,
                                          quietWindow: config.damQuietMinutes * 60)
            processor.controlBooks = Set(config.controlBooks)
            // Only the assistants that are switched on and have said what they do. The transcriber
            // is not among them: it has no connections, which is why it is the transcriber.
            processor.roster = config.assistants
            processor.onChange = { [weak self] in self?.stateChanged() }
            self.processor = processor
            // The panel offers to send a page at once, and the viewer hands single actions over,
            // so both need the same object the timer ticks.
            model?.processor = processor
            actions?.processor = processor
            actions?.roster = config.assistants
            Log.info("pages go to \(account.agentId) at \(account.host) after \(Int(config.damQuietMinutes)) min of quiet")
        } catch {
            Log.error("the DAM agent could not be set up: \(error)")
            notifier.post(Notice(key: "dam-setup", title: "Brainio Pen cannot reach the transcribing agent",
                                 body: error.localizedDescription))
        }
    }

    /// Everything with a name or a number in it. The panel carries almost no words, which only
    /// works because this exists.
    private func showSettings(tab: SettingsView.Tab = .pens) {
        panel?.dismiss()
        if settingsWindow == nil {
            let store = SettingsStore(pens: pens, books: books, config: config, configURL: configURL,
                                      link: session)
            settingsStore = store
            store.onConfigChange = { [weak self] updated in
                guard let self else { return }
                config = updated
                coordinator.quietWindow = updated.quietMinutes * 60
                // The agent, the key or the window may all have changed; rebuilding is cheaper to
                // reason about than patching each field.
                makeProcessor()
                stateChanged()
            }
            settingsWindow = SettingsWindowController(store: store, tab: tab)
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
    private func showViewer(_ page: PageRef?) {
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

    /// The actions, down the right-hand edge. One window, kept open as long as somebody wants it:
    /// an answer arrives while you are doing something else, and it should arrive somewhere you
    /// can see.
    private func showActions(expanding id: String? = nil) {
        panel?.dismiss()
        if actionsWindow == nil {
            actionsWindow = ActionsWindowController(store: actions)
            actionsWindow?.onClose = { [weak self] in self?.actionsWindow = nil }
        }
        actionsWindow?.show(expanding: id)
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
