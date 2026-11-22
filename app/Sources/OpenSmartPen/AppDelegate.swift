import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import Foundation
import OpenSmartPenCore
import OpenSmartPenUI
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let version = "0.3.1"
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

    // Telemetry: what this Mac remembers about it, the SDK while it is sending, and the window
    // that tells the person. See `docs/telemetry.md`.
    private var telemetryState = TelemetryState()
    private var telemetrySink: OTelTelemetry?
    private var telemetryNotice: TelemetryNoticeController?
    /// The first window has not been answered yet.
    private var welcomeOwed = false
    /// The panel stayed open under the Bluetooth question of macOS.
    private var heldForBluetooth = false
    /// The pens have not been started, so that macOS asks about Bluetooth after the first window.
    private var pensWaitForWelcome = false
    private let startedAt = Date()
    private var lastHeartbeat = Date()
    private var lastGauges = Date.distantPast
    private var reportedAgents: Int?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.keep(in: Log.defaultURL)
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
        // Before the updater, the pen and the start at login: all three want the app to be where
        // it will stay. When the person says yes, this copy quits and the one in Applications starts.
        if MoveToApplications.offerIfNeeded() { return }
        // Started here, not when the settings open: the regular check runs from the start.
        updater = Updater()
        Log.info("Open Smart Pen \(Self.version) starting; notes \(config.dataURL.path); config \(configURL.path)")
        // Before anything else is made, so that what the rest of the start does is counted.
        prepareTelemetry()
        // The start, timed from here to the first tick being armed. While the person has not
        // been told about telemetry there is no span, and `app.start` carries the seconds.
        let launch = Telemetry.begin("app.launch")

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
        model.hiddenBooks = Set(config.hiddenBooks)
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
        // The first window is owed: it has the switch for the start at login, so nothing is set
        // up before the person has seen it. And when macOS has not asked about Bluetooth yet, the
        // pens wait too: the first scan is what makes macOS ask, and its question would land on
        // top of ours. A Mac that was asked before has pens to take care of, and they do not wait.
        welcomeOwed = TelemetryPlan.questionIsOwed(asked: telemetryState.noticed, settings: config.telemetry)
        if !welcomeOwed { applyStartAtLogin() }
        model.refresh()
        refreshStatusButton()

        if welcomeOwed, PenSession.bluetoothNotAskedYet {
            pensWaitForWelcome = true
        } else {
            session.start()
        }
        // Often, because the wait before a page is uploaded is counted in seconds. A tick with
        // nothing quiet is a dictionary scan, so it costs nothing to ask.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.coordinator.tick()
            self?.checkAgents()
            self?.stateChanged()
            self?.installUpdateIfQuiet()
            self?.heartbeat()
            self?.reportGauges()
        }

        var start = snapshot()
        start["app.launch"] = .string(launchKind)
        start["app.start_at_login"] = .bool(config.startAtLogin)
        start["sync.quiet_seconds"] = .double(config.quietSeconds)
        start["pen.free_memory_after_sync"] = .bool(config.deleteFromPenAfterPublish)
        start["install.age_days"] = .int(Int(Date().timeIntervalSince(telemetryState.created) / 86400))
        start["app.launch_seconds"] = .double(Date().timeIntervalSince(startedAt))
        launch.set("app.launch", .string(launchKind))
        launch.end()
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
        // Nothing leaves this Mac before the person has said yes. While the question is open,
        // what happens is kept in memory, and sent or thrown away by what they answer.
        if TelemetryPlan.questionIsOwed(asked: telemetryState.noticed, settings: config.telemetry) {
            Telemetry.hold()
            Log.info("telemetry waits for the person's answer")
            return
        }
        switch TelemetryPlan.resolve(settings: config.telemetry) {
        case let .off(reason):
            Log.info("telemetry is off: \(reason)")
        case let .on(plan):
            startTelemetry(plan)
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
        let host = (plan.logs ?? plan.traces ?? plan.metrics)?.host ?? "?"
        Log.info("telemetry goes to \(host); install \(telemetryState.installId). Turn it off in Settings → General")
        reportCrashes()
    }

    /// Stop sending, and delete what was waiting to be sent.
    private func stopTelemetry() {
        Telemetry.stop()
        telemetrySink?.discard()
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

    /// Ask the person, one time, whether the app may report to its makers. Only when the app
    /// could in fact send: a build whose collector is this Mac has nothing to ask.
    private func showTelemetryNoticeIfOwed() {
        guard telemetryNotice == nil,
              TelemetryPlan.questionIsOwed(asked: telemetryState.noticed, settings: config.telemetry) else { return }
        var wanted = config.telemetry
        wanted.enabled = true
        var encrypted = false
        var ours = false
        if case let .on(plan) = TelemetryPlan.resolve(settings: wanted) {
            encrypted = plan.isEncrypted
            ours = plan.goesToProject
        }
        let notice = TelemetryNoticeController(installId: telemetryState.installId, encrypted: encrypted,
                                               ours: ours, startAtLogin: config.startAtLogin)
        notice.onAnswer = { [weak self] yes, login in self?.telemetryNoticeAnswered(keep: yes, startAtLogin: login) }
        telemetryNotice = notice
        NSApp.activate(ignoringOtherApps: true)
        notice.showWindow(nil)
        notice.window?.makeKeyAndOrderFront(nil)
    }

    private func telemetryNoticeAnswered(keep: Bool, startAtLogin: Bool) {
        telemetryNotice = nil
        // What waited for the window goes now, whatever else is true of the answer.
        defer { afterWelcome() }
        guard telemetryState.noticed == nil else { return }
        telemetryState.noticed = Date()
        telemetryState.save(directory: configDirectory)
        // The answer is the setting, each way. The file is read again first: the pen session
        // and the settings window write it too.
        var latest = (try? Config.loadOrCreate(at: configURL)) ?? config
        latest.telemetry.enabled = keep
        latest.startAtLogin = startAtLogin
        do { try latest.save(to: configURL) } catch { Log.error("saving config failed: \(error)") }
        config.telemetry.enabled = keep
        config.startAtLogin = startAtLogin
        settingsStore?.adopt(telemetry: config.telemetry)
        Log.info(keep ? "the first window was answered with telemetry on" : "the first window was answered with telemetry off; nothing was sent")
        applyTelemetry()
    }

    /// The first window is answered or gone: set up the start at login as the switch stood, and
    /// start the pens if they waited. macOS asks about Bluetooth now, after our window and not
    /// on top of it.
    private func afterWelcome() {
        guard welcomeOwed else { return }
        welcomeOwed = false
        applyStartAtLogin()
        settingsStore?.adopt(startAtLogin: config.startAtLogin)
        if pensWaitForWelcome {
            pensWaitForWelcome = false
            session.start()
        }
        openPanelAfterWelcome()
    }

    /// After "Get Started" the panel opens by itself: the app has no other window, and a person
    /// who never used it does not know to look for a pencil in the menu bar. With no pen paired
    /// that is at once: macOS asks about Bluetooth only at "Add Pen". A Mac with a paired pen
    /// and no answer about Bluetooth is asked now, and the panel waits for that answer: it
    /// closes at a click elsewhere, so it would be gone before it was seen.
    private func openPanelAfterWelcome(tries: Int = 0) {
        // Two minutes is long enough for the question. After that the person is elsewhere.
        if session.willAskForBluetooth, tries < 240 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openPanelAfterWelcome(tries: tries + 1)
            }
            return
        }
        // A moment for the window, or the question, to leave the screen and give the focus back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.panel.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.togglePanel()
        }
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

    private static let gaugesEvery: TimeInterval = 60

    /// How things stand now, as metrics. Each minute, which is how often metrics leave: said
    /// more often, only the last value of each minute would be sent.
    private func reportGauges() {
        guard Date().timeIntervalSince(lastGauges) >= Self.gaugesEvery else { return }
        lastGauges = Date()
        Telemetry.measure(.pagesPending, Double(coordinator.pendingPages.count))
        Telemetry.measure(.uploadFailures, Double(coordinator.consecutiveFailures))
        Telemetry.measure(.pensPaired, Double(config.pairedPens.count))
        Telemetry.measure(.pensConnected, Double(session.connections.filter(\.isConnected).count))
        Telemetry.measure(.books, Double(books.books.count))
        Telemetry.measure(.agents, Double(agentRecords.count))
        Telemetry.measure(.uptime, Date().timeIntervalSince(startedAt))
        if let bytes = Self.memoryInUse { Telemetry.measure(.memory, Double(bytes)) }
    }

    /// The memory macOS counts against the app, which is the number Activity Monitor shows.
    /// An app that runs for weeks is where a slow leak shows, and nowhere else.
    private static var memoryInUse: UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// What started this run: the developer's LaunchAgent, the app as a bundle, or a bare binary.
    private var launchKind: String {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return "binary" }
        let agent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/org.opensmartpen.app.plist")
        return FileManager.default.fileExists(atPath: agent.path) ? "launchagent" : "bundle"
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

    /// One entry in the panel, one menu at the mouse: a file, the sample photos, and below them
    /// what macOS adds for each iPhone or iPad near this Mac. The panel stays until the menu closes.
    private func addPhoto() {
        Telemetry.event("ui.photo.menu")
        let menu = PhotoImportController()
        menu.addEntry("Choose a File\u{2026}") { [weak self] in self?.uploadPhoto() }
        menu.addEntry("Use Sample Photo\u{2026}") { [weak self] in self?.showSamples() }
        menu.onImage = { [weak self] data, ext in
            self?.file(photo: data, ext: ext, from: "device", show: true, taken: Date())
        }
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
        file(photo: data, ext: url.pathExtension, from: "drop", show: true, taken: Self.created(url))
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
                Log.warn("could not read \(url.lastPathComponent)", telemetry: false)
                Telemetry.event("photo.rejected", ["photo.source": "file", "photo.reason": "unreadable"], level: .warn)
                continue
            }
            file(photo: data, ext: url.pathExtension.isEmpty ? "jpg" : url.pathExtension, from: "file",
                 show: true, taken: Self.created(url))
        }
    }

    private var sampleGallery: SampleGalleryController?

    /// The window with the sample pages. The one that is clicked is filed as a photo.
    private func showSamples() {
        panel?.dismiss()
        Telemetry.event("ui.photo.samples")
        let gallery = SampleGalleryController { [weak self] sample in
            self?.sampleGallery = nil
            Telemetry.event("ui.photo.sample", ["photo.sample": .string(sample.id)])
            if let picture = sample.png() { self?.file(photo: picture, ext: "png", from: "sample", show: true) }
        }
        sampleGallery = gallery
        NSApp.activate(ignoringOtherApps: true)
        gallery.showWindow(nil)
    }

    /// A photo is complete when it arrives: there is no pen to wait for. So it is drawn and sent now.
    ///
    /// `taken` is what is known about when the photo was taken, if the picture does not say it
    /// itself: now, for one that came from the iPhone a moment ago; the file's own date, for a file.
    /// `source` is where it came from, for telemetry: a file, a drop on the menu bar, the sample,
    /// or an iPhone or iPad.
    private func file(photo: Data, ext: String, from source: String, show: Bool, taken: Date? = nil) {
        // Reading the picture, drawing the page from it and writing both: timed as one piece.
        let span = Telemetry.begin("photo.add", ["photo.source": .string(source), "photo.format": .string(ext.lowercased()),
                                                "photo.bytes": .int(photo.count)])
        guard let page = PhotoPages.add(image: photo, ext: ext, taken: PageImager.taken(inPhoto: photo) ?? taken,
                                        books: books, root: config.dataURL, app: Self.clientID) else {
            span.end(error: "the photo could not be filed")
            Telemetry.event("photo.rejected", ["photo.source": .string(source), "photo.reason": "not filed"], level: .warn)
            return
        }
        span.end()
        Telemetry.count(.photos, ["photo.source": .string(source)])
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

    /// Delete one notebook: from the bucket first, by the names of its files, then from this
    /// Mac. When the bucket refuses, nothing on this Mac is deleted, and the person can try again.
    private func delete(_ book: BookRecord, done: @escaping (String?) -> Void) {
        let folder = book.folder
        let files = books.files(of: folder)
        let client = sync.connection
        agentQueue.async { [weak self] in
            var problem: String?
            if let client {
                do {
                    for file in files { try client.delete(file) }
                } catch {
                    Log.warn("could not delete a notebook from the bucket: \(error)")
                    problem = "The bucket did not delete the notebook: \(error.localizedDescription) "
                        + "Nothing was deleted on this Mac."
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // Deleted from the bucket, or partly: in each case the list of what was uploaded
                // is wrong for these files. What stays on disk goes up again at the next sync.
                if client != nil { self.sync.forget(files) }
                if problem == nil {
                    do {
                        try self.books.delete(folder)
                        self.coordinator.forget(folder)
                    } catch {
                        Log.error("could not delete a notebook from this Mac: \(error)")
                        problem = "The notebook could not be deleted from this Mac: \(error.localizedDescription)"
                    }
                }
                self.model.refreshRecent()
                done(problem)
            }
        }
    }

    /// Remove one agent's record, from the bucket and from the folder.
    private func removeAgent(_ number: Int) {
        let root = config.dataURL, client = sync.connection
        agentQueue.async { [weak self] in
            do {
                try Agents.remove(number, root: root, client: client)
            } catch {
                Log.warn("could not remove an agent's record: \(error)")
            }
            DispatchQueue.main.async {
                self?.showAgents()
                self?.pushSyncStatus()
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
        panel.holdsOpen = { [weak self] in self?.session.asksForBluetoothToAdd ?? false }
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
                                   connected: session.isAnyConnected, refused: model.bluetoothRefused)
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
        status.agents = agentRecords.map { SyncStatus.Agent(id: $0.number, name: $0.name) }
        status.agentSentence = model.agentSentence
        if store.sync != status { store.sync = status }
    }

    /// Everything with a name or a number in it. The panel carries almost no words, which only
    /// works because this exists.
    private func showSettings(tab: SettingsTab? = nil) {
        panel?.dismiss()
        if settingsWindow == nil {
            let log = Log.defaultURL
            var info = AppInfo(version: Self.version, sdk: Self.sdkVersion.replacingOccurrences(of: "/", with: " "),
                               configURL: configURL, logURL: log)
            info.updates = updater?.controls
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
                model.hiddenBooks = Set(updated.hiddenBooks)
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
            store.onDeleteBook = { [weak self] book, done in self?.delete(book, done: done) }
            store.onRemoveAgent = { [weak self] number in self?.removeAgent(number) }
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
        // The first window comes before the app: a click on the pencil shows it again, and the
        // panel opens only after "Get Started".
        if welcomeOwed {
            if let telemetryNotice { telemetryNotice.comeForward() } else { showTelemetryNoticeIfOwed() }
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
        // The question of macOS took the keyboard from the panel. Take it back when the question
        // is answered, so that Escape and a click elsewhere close the panel as before.
        if session.asksForBluetoothToAdd {
            heldForBluetooth = true
        } else if heldForBluetooth {
            heldForBluetooth = false
            if panel?.isVisible == true {
                NSApp.activate(ignoringOtherApps: true)
                panel?.makeKey()
            }
        }
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
