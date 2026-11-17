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
    /// So a new notebook is only looked up when the pen moves to a different one, rather than on
    /// every dot.
    private var lastSeenBook: String?
    private var viewer: Viewer!
    private var viewerWindow: ViewerWindowController?
    private var pinnedPanel: PinnedPanelController?
    private var tickTimer: Timer?
    /// Runs only while the panel is open; drives the per-page countdowns.
    private var panelTimer: Timer?
    private var panelNow = Date()

    // Telemetry: what this Mac remembers about it, the SDK while it is sending, and the window
    // that tells the person. See `docs/telemetry.md`.
    private var telemetryState = TelemetryState()
    private var telemetrySink: OTelTelemetry?
    private var telemetryNotice: TelemetryNoticeController?
    private let startedAt = Date()
    private var lastHeartbeat = Date()
    private var reportedAgents: Int?

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
        Log.info("Open Smart Pen \(Self.version) starting; notes \(config.dataURL.path); config \(configURL.path)")
        // Before anything else is made, so that what the rest of the start does is counted.
        prepareTelemetry()

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
            // A notebook Open Smart Pen has never met gets a record the moment a page arrives from it,
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
        model.onShowLive = { [weak self] in self?.showViewer(nil) }
        model.onTogglePin = { [weak self] in self?.togglePinned() }
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        model.onAddPhoto = { [weak self] in self?.addPhoto() }
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
            self?.heartbeat()
        }

        var start = snapshot()
        start["app.launch"] = .string(launchKind)
        start["app.start_at_login"] = .bool(config.startAtLogin)
        start["sync.quiet_seconds"] = .double(config.quietSeconds)
        start["pen.free_memory_after_sync"] = .bool(config.deleteFromPenAfterPublish)
        start["install.age_days"] = .int(Int(Date().timeIntervalSince(telemetryState.created) / 86400))
        Telemetry.event("app.start", start)
        // After the first turn of the run loop, so the window comes up on a finished app.
        DispatchQueue.main.async { [weak self] in self?.showTelemetryNoticeIfOwed() }
    }

    // MARK: - telemetry

    private var configDirectory: URL { configURL.deletingLastPathComponent() }

    /// Read the install id and decide what telemetry does in this run: nothing, wait for the
    /// person to be told, or send.
    private func prepareTelemetry() {
        telemetryState = TelemetryState.load(directory: configDirectory)
        hidePrivateText()
        switch TelemetryPlan.resolve(settings: config.telemetry) {
        case let .off(reason):
            Log.info("telemetry is off: \(reason)")
        case let .on(plan):
            if telemetryState.noticed == nil {
                // Nothing leaves this Mac before the person has been told. What happens until
                // then is kept in memory, and sent or thrown away by what they answer.
                Telemetry.hold()
                Log.info("telemetry waits until the person has been told about it")
            } else {
                startTelemetry(plan)
            }
        }
    }

    private func startTelemetry(_ plan: TelemetryPlan) {
        guard telemetrySink == nil else { return }
        for note in plan.notes { Log.info("telemetry: \(note)") }
        let sink = OTelTelemetry(plan: plan,
                                 resource: OTelTelemetry.resource(plan: plan, installId: telemetryState.installId),
                                 queue: OTelTelemetry.queueLocation)
        telemetrySink = sink
        Telemetry.start(sink)
        let host = (plan.logs ?? plan.traces)?.host ?? "?"
        Log.info("telemetry goes to \(host); install \(telemetryState.installId). Turn it off in Settings → General")
        reportCrashes()
    }

    /// Stop sending, and delete what was waiting to be sent.
    private func stopTelemetry() {
        Telemetry.stop()
        telemetrySink?.shutdown()
        telemetrySink = nil
        OTelTelemetry.emptyQueue()
    }

    /// The setting changed, in the settings window or in the notice.
    private func applyTelemetry() {
        hidePrivateText()
        switch TelemetryPlan.resolve(settings: config.telemetry) {
        case let .off(reason):
            if telemetrySink != nil || !config.telemetry.enabled { Log.info("telemetry is off: \(reason)") }
            stopTelemetry()
        case let .on(plan):
            // A person who turns it on in Settings has read what it is, there.
            if telemetryState.noticed == nil {
                telemetryState.noticed = Date()
                telemetryState.save(directory: configDirectory)
            }
            telemetryNotice?.close()
            startTelemetry(plan)
        }
    }

    /// The bucket, its folder and its key id never leave in an error message, nor does a notes
    /// folder that is somewhere other than the home folder.
    private func hidePrivateText() {
        var scrubber = TelemetryScrubber()
        scrubber.hide(config.s3.bucket, as: "bucket")
        scrubber.hide(config.s3.prefix, as: "folder")
        scrubber.hide(config.s3.accessKeyId, as: "key-id")
        scrubber.hide(config.s3.endpoint, as: "endpoint")
        if let host = config.s3Account()?.endpoint.host, !host.hasSuffix("amazonaws.com") {
            scrubber.hide(host, as: "endpoint")
        }
        if !config.dataURL.path.hasPrefix(scrubber.home) { scrubber.hide(config.dataURL.path, as: "notes") }
        Telemetry.scrubber = scrubber
    }

    /// Tell the person, once, that the app reports to its makers, and let them turn it off.
    /// Only when the app would in fact send: a build with no collector has nothing to say.
    private func showTelemetryNoticeIfOwed() {
        guard telemetryState.noticed == nil, telemetryNotice == nil, config.telemetry.enabled,
              case .on = TelemetryPlan.resolve(settings: config.telemetry) else { return }
        let notice = TelemetryNoticeController(installId: telemetryState.installId)
        notice.onAnswer = { [weak self] keep in self?.telemetryNoticeAnswered(keep: keep) }
        telemetryNotice = notice
        NSApp.activate(ignoringOtherApps: true)
        notice.showWindow(nil)
        notice.window?.makeKeyAndOrderFront(nil)
    }

    private func telemetryNoticeAnswered(keep: Bool) {
        telemetryNotice = nil
        guard telemetryState.noticed == nil else { return }
        telemetryState.noticed = Date()
        telemetryState.save(directory: configDirectory)
        if !keep {
            // The file is read again first: the pen session and the settings window write it too.
            var latest = (try? Config.loadOrCreate(at: configURL)) ?? config
            latest.telemetry.enabled = false
            do { try latest.save(to: configURL) } catch { Log.error("saving config failed: \(error)") }
            config.telemetry.enabled = false
            settingsStore?.adopt(telemetry: config.telemetry)
            Log.info("telemetry was turned off in the notice; nothing was sent")
        }
        applyTelemetry()
    }

    /// Crashes since the last start, read from the reports macOS wrote. Off the main thread: the
    /// folder holds the reports of every process this person runs.
    private func reportCrashes() {
        let since = telemetryState.crashesReadTo ?? telemetryState.created
        let process = ProcessInfo.processInfo.processName
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let now = Date()
            let reports = CrashReport.recent(in: CrashReport.directory, process: process, after: since)
            for report in reports {
                Telemetry.event("app.crash", [
                    "exception.type": .string(report.kind),
                    "exception.message": .string(report.message),
                    "exception.stacktrace": .string(report.stack),
                    "crash.incident_id": .string(report.incident),
                    "crash.app_version": .string(report.appVersion),
                    "crash.os_version": .string(report.osVersion),
                    "crash.binary_uuid": .string(report.binaryUUID),
                ], level: .fatal, body: "\(report.kind): \(report.message)", time: report.time)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if !reports.isEmpty { Log.info("reported \(reports.count) crash(es) of an earlier run") }
                self.telemetryState.crashesReadTo = now
                self.telemetryState.save(directory: self.configDirectory)
            }
        }
    }

    /// How things stand, in numbers. Sent at the start and every few hours, so an app that runs
    /// for a month is still counted as one that is in use.
    private func snapshot() -> [String: TelemetryValue] {
        [
            "pens.paired": .int(config.pairedPens.count),
            "pens.connected": .int(session?.connections.filter(\.isConnected).count ?? 0),
            "bucket.connected": .bool(sync?.isConnected ?? false),
            "agents.count": .int(agentRecords.count),
            "books.count": .int(books?.books.count ?? 0),
            "pages.pending": .int(coordinator?.pendingPages.count ?? 0),
            "app.uptime_seconds": .int(Int(Date().timeIntervalSince(startedAt))),
        ]
    }

    private static let heartbeatEvery: TimeInterval = 6 * 60 * 60

    private func heartbeat() {
        guard Date().timeIntervalSince(lastHeartbeat) >= Self.heartbeatEvery else { return }
        lastHeartbeat = Date()
        Telemetry.event("app.heartbeat", snapshot())
    }

    /// What started this run: the developer's LaunchAgent, the app as a bundle, or a bare binary.
    private var launchKind: String {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return "binary" }
        let agent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/org.opensmartpen.app.plist")
        return FileManager.default.fileExists(atPath: agent.path) ? "launchagent" : "bundle"
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
        Telemetry.event("ui.photo.menu")
        let menu = PhotoImportController()
        menu.addEntry("Choose a File\u{2026}") { [weak self] in self?.uploadPhoto() }
        if books.current(for: PhotoPages.surface) == nil {
            menu.addEntry("Use the Sample Page") { [weak self] in self?.addSample() }
        }
        menu.onImage = { [weak self] data, ext in self?.file(photo: data, ext: ext, from: "device", show: true) }
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
            // The name of a person's file stays in the log on this Mac.
            Log.warn("\(url.lastPathComponent) is not a picture; not added", telemetry: false)
            Telemetry.event("photo.rejected", ["photo.source": "drop", "photo.reason": "not a picture"], level: .warn)
            return
        }
        file(photo: data, ext: url.pathExtension, from: "drop", show: true)
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
                Log.warn("could not read \(url.lastPathComponent)", telemetry: false)
                Telemetry.event("photo.rejected", ["photo.source": "file", "photo.reason": "unreadable"], level: .warn)
                continue
            }
            file(photo: data, ext: url.pathExtension.isEmpty ? "jpg" : url.pathExtension, from: "file", show: true)
        }
    }

    /// The page the app brings itself, for a person with no pen and no photo at hand who wants to
    /// see an agent read something. Offered only until the Photos notebook exists: the notebook
    /// is made when the first picture is filed, and not before.
    private func addSample() {
        panel?.dismiss()
        if let picture = SamplePicture.png() { file(photo: picture, ext: "png", from: "sample", show: true) }
    }

    /// A photo is complete when it arrives: there is no pen to wait for. So it is drawn and sent now.
    ///
    /// `source` is where it came from, for telemetry: a file, a drop on the menu bar, the sample,
    /// or an iPhone or iPad.
    private func file(photo: Data, ext: String, from source: String, show: Bool) {
        guard let page = PhotoPages.add(image: photo, ext: ext, books: books, root: config.dataURL,
                                        app: Self.clientID) else { return }
        Log.info("a photo is filed as \(page)")
        Telemetry.event("photo.added", ["photo.source": .string(source), "photo.format": .string(ext.lowercased()),
                                        "photo.bytes": .int(photo.count)])
        coordinator.recoverPending()
        coordinator.publish(pages: [page], reason: "photo") { [weak self] _ in
            DispatchQueue.main.async {
                self?.model.refreshRecent()
                if show { self?.showViewer(page) }
            }
        }
    }

    /// Read the agents' records: from the folder each time, from the bucket once a minute.
    private func checkAgents() {
        model.agentSentence = Agents.sentence(folder: config.dataURL,
                                              bucket: config.s3Account()?.destination)
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
        let changed = Agents.lastChange(root: config.dataURL)
        model.setAgents(agentRecords, changed: changed)
        // How many agents, and how many are behind. Not their names: an agent writes its own.
        if reportedAgents != agentRecords.count {
            if reportedAgents != nil {
                Telemetry.event("agents.changed", [
                    "agents.count": .int(agentRecords.count),
                    "agents.behind": .int(agentRecords.filter { $0.isBehind(changed: changed) }.count),
                ])
            }
            reportedAgents = agentRecords.count
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("Open Smart Pen stopping")
        Telemetry.event("app.stop", snapshot())
        // What has gathered goes to the queue on disk now. What does not reach the collector
        // before the process ends is sent at the next start.
        telemetrySink?.flush()
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
            case "q":
                Telemetry.event("ui.quit")
                NSApp.terminate(nil)
                return true
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
            info.installId = telemetryState.installId
            let store = SettingsStore(pens: pens, books: books, config: config, configURL: configURL,
                                      info: info, link: session)
            settingsStore = store
            store.onConfigChange = { [weak self] updated in
                guard let self else { return }
                let bucketChanged = updated.s3 != config.s3 || sync.isConnected != (updated.s3Account() != nil)
                let telemetryChanged = updated.telemetry != config.telemetry
                config = updated
                coordinator.quietWindow = updated.quietSeconds
                applyStartAtLogin()
                if bucketChanged { connectBucket() }
                // A bucket's name is hidden from the moment it is connected. Only a change to the
                // telemetry setting itself turns telemetry on or off.
                hidePrivateText()
                if telemetryChanged { applyTelemetry() }
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
        Telemetry.event("ui.settings.opened")
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
        Telemetry.event("ui.panel.pinned")
        let origin = panel.isVisible ? panel.frame : nil
        panel?.dismiss()
        let controller = PinnedPanelController(model: model, now: panelNow, from: origin)
        controller.onClose = { [weak self] in
            self?.pinnedPanel = nil
            self?.model.setPinned(false)
            Telemetry.event("ui.panel.unpinned")
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
        Telemetry.event("ui.viewer.opened", ["viewer.target": .string(page == nil ? "latest" : "page")])
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
        Telemetry.event("ui.panel.opened")
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
