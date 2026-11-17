import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import Foundation
import OpenSmartPenCore
import OpenSmartPenUI
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let version = "0.2.0"
    static let sdkVersion = "NISDK3/1.1.5"
    /// The build that writes a raw file, for its header line. Every raw file the app creates says
    /// this, so a file can always be traced to what made it.
    static let clientID = "opensmartpen-mac/\(version)"

    private var statusItem: NSStatusItem!
    private var panel: MenuBarPanel!
    private var panelHost: NSHostingController<StatusPanel>!
    private var config = Config()
    private let configURL = Config.defaultLocation
    private var coordinator: SyncCoordinator!
    /// Copies quiet pages to the bucket. Does nothing, successfully, until one is connected.
    private var sync: S3Sync!
    private var session: PenSession!
    private var notifier: DedupingNotifier!
    private var model: PanelModel!
    private var books: BookRegistry!
    private var pens: PenRegistry!
    private var penState: PenState!
    private var settingsWindow: SettingsWindowController?
    private var settingsStore: SettingsStore?
    /// Nil in a build with no update feed.
    private var updater: Updater?
    /// So a new notebook is only looked up when the pen moves to a different one, rather than on
    /// every dot.
    private var lastSeenBook: String?
    private var firstInk = FirstInk()
    private var viewer: Viewer!
    private var viewerWindow: ViewerWindowController?
    private var pinnedPanel: PinnedPanelController?
    private var tickTimer: Timer?
    /// Runs only while the panel is open; drives the per-page countdowns.
    private var panelTimer: Timer?
    private var panelNow = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.verbose = ProcessInfo.processInfo.environment["OPENSMARTPEN_VERBOSE"] != nil

        let base: Notifier = UserNotifier.isAvailable ? UserNotifier() : OSAScriptNotifier()
        notifier = DedupingNotifier(base)

        do {
            config = try Config.loadOrCreate(at: configURL)
        } catch {
            Log.error("config unreadable, using defaults: \(error)")
            notifier.post(Notice(key: "config", title: "Open Smart Pen config is invalid",
                                 body: "\(configURL.path): \(error.localizedDescription). Running with defaults."))
        }
        // Started here, not when the settings open: the regular check runs from the start.
        updater = Updater()
        Log.info("Open Smart Pen \(Self.version) starting; notes \(config.dataURL.path); config \(configURL.path)")

        // The notes live in the folder. The bucket is a copy of it, made as pages go quiet, and
        // the list of what has been copied sits beside the config: it is a fact about this Mac.
        sync = S3Sync(root: config.dataURL,
                      ledger: configURL.deletingLastPathComponent().appendingPathComponent("s3-uploaded.json"))

        let store = RawStore(root: config.dataURL, app: Self.clientID, sdk: Self.sdkVersion)
        // Notebook names, page numbering and the readable-file paths all come from
        // books/<copy>/book.json, which the processing side also reads. One source, no drift.
        books = BookRegistry(root: config.dataURL)
        let router = PageRouter(books: books, store: store)
        router.adoptExisting()
        // Each page gets a picture in the folder first, bucket or no bucket, and then goes on to
        // the bucket. The picture is what an agent looks at, on this Mac or on the other side.
        let pictures = PagePictures(root: config.dataURL, next: sync)
        pictures.controlBooks = Set(config.controlBooks)
        coordinator = SyncCoordinator(store: store, router: router, tracker: QuietTracker(),
                                      publisher: pictures, notifier: notifier,
                                      quietWindow: config.quietSeconds)
        coordinator.controlBooks = Set(config.controlBooks)
        coordinator.modeLog = ModeLog(root: config.dataURL, app: Self.clientID, sdk: Self.sdkVersion)
        // The page's picture is drawn the way the viewer draws it, from the same strokes.
        pictures.imaging = PageImager(books: books, root: config.dataURL, modeLog: coordinator.modeLog,
                                      controlBooks: Set(config.controlBooks))
        connectBucket()

        session = PenSession(config: config, configURL: configURL, coordinator: coordinator, notifier: notifier)

        pens = PenRegistry(repo: config.dataURL)
        penState = PenState(directory: configURL.deletingLastPathComponent())
        // The palette decides which of the strip's ten buttons mean anything. Narrowing the set is
        // an edit to one file in the repo, not a code change.
        coordinator.modeLog?.offered = Set(Palette.load(root: config.dataURL).offered)
        viewer = Viewer(books: books, repo: config.dataURL)
        // The one thing read from the bucket: the transcript of the page on screen, which
        // whatever reads the bucket wrote there. The app still transcribes nothing.
        viewer.transcripts = TranscriptStore(root: config.dataURL) { [sync] in sync?.connection }
        // Paper we capture from but never read back. The coordinator still stores every tap and
        // decodes it as a command; what stops here is everything that treats a book as a
        // notebook — a record of its own and the live page in the viewer.
        let controlBooks = Set(config.controlBooks)
        session.onDot = { [weak self] page, dot, event in
            guard let self else { return }
            // Every dot, the control strip's included: the upload waits for the pen to go
            // quiet, and a pen that is tapping is not quiet.
            coordinator.penActive()
            guard !controlBooks.contains(page.surface) else { return }
            // A notebook Open Smart Pen has never met gets a record as soon as real writing
            // arrives from it, so its pages stop being anonymous and start being rendered. Silent
            // on purpose: writing is never interrupted to ask a question. Not at the first
            // sample, though. Near the edge of a sheet the pen now and then reads the wrong
            // notebook for one sample, and a record made from that is a notebook of one dot.
            if lastSeenBook != page.surface {
                if books.current(for: page.surface) == nil {
                    guard firstInk.isNotebook(page.surface) else { return }
                    books.ensureRecord(for: page)
                }
                lastSeenBook = page.surface
            }
            viewer.receive(page: page, dot: dot, event: event)
        }
        model = PanelModel(session: session, coordinator: coordinator, config: config,
                           books: books, pens: pens, penState: penState)
        model.onShowLive = { [weak self] in self?.showViewer(nil) }
        model.onTogglePin = { [weak self] in self?.togglePinned() }
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        model.onAddPhoto = { [weak self] in self?.addPhoto() }
        model.onSetUpAgent = { [weak self] id in self?.setUpAgent(id) }
        model.onOpenPage = { [weak self] page in self?.showViewer(page) }
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
        // `--show-settings=sync` opens it on that tab, so each one can be looked at in turn.
        if let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--show-settings") }) {
            let named = flag.split(separator: "=").dropFirst().first.map(String.init)
            showSettings(tab: SettingsTab.allCases.first { "\($0)" == named } ?? .sync)
        }
        checkAgents()
        applyStartAtLogin()
        model.refresh()
        refreshStatusButton()

        session.start()
        // Often, because the wait before a page is uploaded is counted in seconds. A tick with
        // nothing quiet is a dictionary scan, so it costs nothing to ask.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.coordinator.tick()
            self?.checkAgents()
            self?.stateChanged()
            self?.installUpdateIfQuiet()
        }
    }

    // MARK: - updates

    /// An update that is downloaded waits here for a moment that nobody notices, and then the app
    /// restarts itself. See `UpdateMoment` for what such a moment is.
    private func installUpdateIfQuiet() {
        guard let updater, updater.isWaiting else { return }
        let moment = UpdateMoment(
            lastPenActivity: coordinator.lastActivity,
            pendingPages: coordinator.pendingPages.count,
            isPublishing: coordinator.isPublishing,
            isCopyingFromPen: session.connections.contains { $0.drain != nil || $0.state == .connecting },
            // Not the pinned panel: a person can keep that one open all day.
            windowIsOpen: panelTimer != nil
                || settingsWindow?.window?.isVisible == true
                || viewerWindow?.window?.isVisible == true)
        guard moment.isQuiet() else { return }
        session.letGoForRestart()
        updater.installNow()
    }

    // MARK: - starting at login

    /// Make macOS start the app at login, or stop it doing so, as the setting says.
    ///
    /// Only for an app in a bundle, which is what macOS registers. And not on a Mac where the
    /// developer's LaunchAgent is installed: that already starts the app, and two starters would
    /// start two copies, which would both take the pen.
    private func applyStartAtLogin() {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let agent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/org.opensmartpen.app.plist")
        guard !FileManager.default.fileExists(atPath: agent.path) else {
            Log.debug("started by the LaunchAgent; the login item is left alone")
            return
        }
        let service = SMAppService.mainApp
        do {
            if config.startAtLogin, service.status != .enabled {
                try service.register()
                Log.info("the app starts at login")
            } else if !config.startAtLogin, service.status == .enabled {
                try service.unregister()
                Log.info("the app no longer starts at login")
            }
        } catch {
            Log.warn("could not change whether the app starts at login: \(error.localizedDescription)")
        }
    }

    // MARK: - the agents, and pages that are pictures

    private var agentRecords: [AgentRecord] = []
    private var agentsAsked = Date.distantPast
    private let agentQueue = DispatchQueue(label: "org.opensmartpen.app.agent")

    private var photoImport: PhotoImportController?

    /// One entry in the panel, one menu at the mouse: a file, the sample while there is no Photos
    /// notebook, and below them what macOS adds for each iPhone or iPad near this Mac. The panel
    /// stays until the menu closes.
    private func addPhoto() {
        let menu = PhotoImportController()
        menu.addEntry("Choose a File\u{2026}") { [weak self] in self?.uploadPhoto() }
        if books.current(for: PhotoPages.surface) == nil {
            menu.addEntry("Use the Sample Page") { [weak self] in self?.addSample() }
        }
        menu.onImage = { [weak self] data, ext in self?.file(photo: data, ext: ext, show: true, taken: Date()) }
        menu.onFinish = { [weak self] in self?.photoImport = nil }
        photoImport = menu
        panel?.staysOpen = true
        menu.onMenuClosed = { [weak self] in
            self?.panel?.staysOpen = false
            self?.panel?.dismiss()
        }
        menu.show()
    }

    /// A file dropped on the pen in the menu bar. Only a picture is taken.
    private func addPhoto(file url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let data = try? Data(contentsOf: url) else {
            Log.warn("\(url.lastPathComponent) is not a picture; not added")
            return
        }
        file(photo: data, ext: url.pathExtension, show: true, taken: Self.created(url))
    }

    /// When a file was made, which for a photo that says nothing itself is the best there is.
    private static func created(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// A picture of a page from a file.
    private func uploadPhoto() {
        panel?.dismiss()
        NSApp.activate(ignoringOtherApps: true)
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = [.image]
        chooser.allowsMultipleSelection = true
        chooser.message = "Choose a photo of a page. Each photo becomes a page in the notebook \u{201C}Photos\u{201D}."
        chooser.prompt = "Add"
        guard chooser.runModal() == .OK else { return }
        for url in chooser.urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url) else {
                Log.warn("could not read \(url.lastPathComponent)")
                continue
            }
            file(photo: data, ext: url.pathExtension.isEmpty ? "jpg" : url.pathExtension, show: true,
                 taken: Self.created(url))
        }
    }

    /// The page the app brings itself, for a person with no pen and no photo at hand who wants to
    /// see an agent read something. Offered only until the Photos notebook exists: the notebook
    /// is made when the first picture is filed, and not before.
    private func addSample() {
        panel?.dismiss()
        if let picture = SamplePicture.png() { file(photo: picture, ext: "png", show: true) }
    }

    /// A photo is complete when it arrives: there is no pen to wait for. So it is drawn and sent now.
    ///
    /// `taken` is what is known about when the photo was taken, if the picture does not say it
    /// itself: now, for one that came from the iPhone a moment ago; the file's own date, for a file.
    private func file(photo: Data, ext: String, show: Bool, taken: Date? = nil) {
        guard let page = PhotoPages.add(image: photo, ext: ext, taken: PageImager.taken(inPhoto: photo) ?? taken,
                                        books: books, root: config.dataURL, app: Self.clientID) else { return }
        Log.info("a photo is filed as \(page)")
        coordinator.recoverPending()
        coordinator.publish(pages: [page], reason: "photo") { [weak self] _ in
            DispatchQueue.main.async {
                self?.model.refreshRecent()
                if show { self?.showViewer(page) }
            }
        }
    }

    /// Start a new agent in the notes folder, with the sentence that sends it to the website.
    private func setUpAgent(_ id: String) {
        panel?.dismiss()
        switch id {
        case "claude-cowork":
            if let link = Agents.coworkLink(folder: config.dataURL, bucket: config.s3Account()?.destination) {
                NSWorkspace.shared.open(link)
            }
        case "claude-code":
            guard let claude = Agents.claudeCommand() else { return }
            // A `.command` file is what the Terminal runs when it is opened. It needs no
            // permission to control the Terminal, which a script sent to it would.
            let script = FileManager.default.temporaryDirectory
                .appendingPathComponent("Set up Open Smart Pen agent.command")
            do {
                try Agents.terminalScript(folder: config.dataURL, bucket: config.s3Account()?.destination,
                                          claude: claude)
                    .write(to: script, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
                NSWorkspace.shared.open(script)
            } catch {
                Log.warn("could not start Claude Code in the Terminal: \(error)")
            }
        default:
            break
        }
    }

    /// Read the agents' records: from the folder each time, from the bucket once a minute.
    private func checkAgents() {
        model.agentSentence = Agents.sentence(folder: config.dataURL,
                                              bucket: config.s3Account()?.destination)
        // Asked each time: an agent can be installed or removed while this runs.
        var found: [PanelModel.NewAgent] = []
        if Agents.claudeCommand() != nil {
            found.append(.init(id: "claude-code", title: "Claude Code", note: "Fast \u{00B7} recommended",
                               recommended: true))
        }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: Agents.claudeDesktop) != nil {
            found.append(.init(id: "claude-cowork", title: "Claude Cowork",
                               note: found.isEmpty ? "Checks each hour" : "Simple \u{00B7} checks each hour",
                               recommended: found.isEmpty))
        }
        if model.newAgents != found { model.newAgents = found }
        if let client = sync.connection, Date().timeIntervalSince(agentsAsked) > 60 {
            agentsAsked = Date()
            let root = config.dataURL
            agentQueue.async { [weak self] in
                Agents.fetch(root: root, client: client)
                DispatchQueue.main.async { self?.showAgents() }
            }
        }
        showAgents()
    }

    private func showAgents() {
        agentRecords = Agents.load(root: config.dataURL)
        model.setAgents(agentRecords, changed: Agents.lastChange(root: config.dataURL))
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("Open Smart Pen stopping")
    }

    // MARK: status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        // A picture dropped on the pen in the menu bar is added as a page. The panel cannot take
        // a drop from the Finder itself: it closes at the click that starts the drag.
        statusItem.button?.window?.registerForDraggedTypes([.fileURL])
        statusItem.button?.window?.delegate = self

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
        pushSyncStatus()
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
                                 body: "Give it a name in Open Smart Pen settings."))
            settingsStore?.reload()
        }
    }

    /// Point the uploads at the bucket in the config, or at nothing.
    ///
    /// Every part is needed — the bucket, the key id, and the secret, which is in a file of its
    /// own — so a config carried to another Mac starts with no bucket rather than a broken one.
    /// Whatever is on disk and not in that bucket is then found and queued: on a first connection
    /// that is every page there is.
    private func connectBucket() {
        if let account = config.s3Account() {
            sync.connect(S3Client(account: account))
            Log.info("pages go to \(account.destination) after \(Int(config.quietSeconds)) s of quiet")
        } else {
            sync.connect(nil)
            Log.info("no bucket connected; pages and their pictures stay on this Mac")
        }
        coordinator.recoverPending()
    }

    /// What the Sync tab shows. Only while the window exists, and only when something moved.
    private func pushSyncStatus() {
        guard let store = settingsStore else { return }
        var status = SyncStatus()
        status.uploading = coordinator.isPublishing
        status.pending = coordinator.pendingPages.count
        status.lastUpload = coordinator.lastPublish?.date
        status.lastFiles = coordinator.lastPublish?.files ?? 0
        status.error = coordinator.lastError
        status.agents = agentRecords.map(\.name)
        status.agentSentence = model.agentSentence
        if store.sync != status { store.sync = status }
    }

    /// Everything with a name or a number in it. The panel carries almost no words, which only
    /// works because this exists.
    private func showSettings(tab: SettingsTab? = nil) {
        panel?.dismiss()
        if settingsWindow == nil {
            let log = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/OpenSmartPen/opensmartpen.log")
            var info = AppInfo(version: Self.version, sdk: Self.sdkVersion.replacingOccurrences(of: "/", with: " "),
                               configURL: configURL, logURL: log)
            info.updates = updater?.controls
            let store = SettingsStore(pens: pens, books: books, config: config, configURL: configURL,
                                      info: info, link: session)
            settingsStore = store
            store.onConfigChange = { [weak self] updated in
                guard let self else { return }
                let bucketChanged = updated.s3 != config.s3 || sync.isConnected != (updated.s3Account() != nil)
                config = updated
                coordinator.quietWindow = updated.quietSeconds
                applyStartAtLogin()
                if bucketChanged { connectBucket() }
                stateChanged()
            }
            // A new title is a changed file with no page to carry it, so it is sent now.
            store.onRecordsChange = { [weak self] in self?.coordinator.publishAll() }
            store.onSyncNow = { [weak self] in
                self?.coordinator.publishAll()
                self?.stateChanged()
            }
            settingsWindow = SettingsWindowController(store: store, tab: tab ?? .pens)
            pushSyncStatus()
        } else if let tab {
            settingsWindow?.select(tab)
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
    /// and a page is readable before anything else has touched it.
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

// MARK: - a picture dropped on the menu bar

extension AppDelegate: NSWindowDelegate {
    private func pictures(in info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    }

    @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pictures(in: sender).isEmpty ? [] : .copy
    }

    @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = pictures(in: sender)
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) { addPhoto(file: url) }
        return !urls.isEmpty
    }
}
