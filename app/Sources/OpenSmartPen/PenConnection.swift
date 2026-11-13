import CoreBluetooth
import Foundation
import NISDK3
import OpenSmartPenCore
import OpenSmartPenUI

/// One connected pen, from the moment Bluetooth links it until it goes away: authorises, sets the
/// clock, drains offline memory notebook by notebook, and forwards live strokes. Finding pens and
/// deciding which ones to accept is `PenSession`'s job; this object only ever talks to its own pen.
/// All SDK callbacks are marshalled onto the main queue.
final class PenConnection: NSObject {
    typealias State = PenLinkState
    typealias Drain = DrainProgress

    let peripheral: CBPeripheral
    let pen: PenController

    private(set) var state: State = .authorizing { didSet { if state != oldValue { onChange?() } } }
    private(set) var drain: Drain? { didSet { if drain != oldValue { onChange?() } } }
    private(set) var setting: PenSettingStruct?
    private(set) var name: String
    /// Lowercase and unpunctuated. From the advertisement until the pen confirms it on authorising.
    private(set) var mac: String
    private(set) var lastDot: Date?

    var onChange: (() -> Void)?
    /// Every dot as it arrives, before assembly. See `PenSession.onDot`.
    var onDot: ((PageID, DotSample, DotEvent) -> Void)?
    /// The pen has accepted us. The session decides here whether it is a pen worth keeping.
    var onAuthorised: ((PenConnection) -> Void)?

    var isConnected: Bool {
        switch state {
        case .ready, .draining: return true
        default: return false
        }
    }

    private let config: Config
    private let configURL: URL
    private let coordinator: SyncCoordinator
    private let notifier: DedupingNotifier

    private var stepTimer: Timer?
    private var settingTimer: Timer?
    private var passwordTried = false
    private var powerWriteAttempted = false
    private var assembler = StrokeAssembler()
    /// Samples the pen took and could not read, gathered so they are reported once a window.
    private var unread = UnreadInk()
    private var unreadTimer: Timer?
    /// The SDK's own MAC string, unnormalised, as every stroke has always carried it.
    private var strokeMac = ""
    private var firmware = ""

    private struct Note { let section: UInt8; let owner: UInt32; let note: UInt32 }
    private var drainQueue: [Note] = []
    private var draining: Note?
    private var drainedPages: Set<PageRef> = []
    private var drainedStrokes = 0
    /// Books in this drain, fixed when the list arrives so "2 of 3" does not renumber as it empties.
    private var drainTotal = 0

    init(pen: PenController, peripheral: CBPeripheral, name: String, mac: String, config: Config,
         configURL: URL, coordinator: SyncCoordinator, notifier: DedupingNotifier) {
        self.pen = pen
        self.peripheral = peripheral
        self.name = name
        self.mac = PenRecord.normalise(mac)
        self.config = config
        self.configURL = configURL
        self.coordinator = coordinator
        self.notifier = notifier
        super.init()
    }

    /// Notification keys are per pen, so one pen's flat battery does not silence another's.
    private func key(_ base: String) -> String {
        "\(base)-\(mac.isEmpty ? peripheral.identifier.uuidString : mac)"
    }

    private var displayName: String { name.isEmpty ? "the pen" : name }

    func start() {
        pen.setPenDelegate(self)
        pen.showSDKLog(config.sdkDebugLog)
        state = .authorizing
        armStep(20) { [weak self] in
            guard let self, self.state == .authorizing else { return }
            Log.warn("authorisation of \(self.displayName) timed out; disconnecting")
            self.pen.disConnect()
        }
    }

    func disconnect() { pen.disConnect() }

    func requestSettingRefresh() { pen.requestPenSettingInfo() }

    func showOnLED(_ rgb: (r: Double, g: Double, b: Double)) {
        guard isConnected else { return }
        pen.requestSetPenLEDColor(SDKMapping.led(nearest: rgb))
    }

    var info: PenConnectionInfo {
        PenConnectionInfo(mac: mac, name: name, state: state, drain: drain,
                          reading: setting.map {
                              PenReport(battery: Int($0.battLevel), charging: $0.charging == .On,
                                        memoryUsedPercent: Int($0.memoryUsed))
                          },
                          lastDot: lastDot)
    }

    private func armStep(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        stepTimer?.invalidate()
        stepTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in block() }
    }

    private func disarmStep() {
        stepTimer?.invalidate()
        stepTimer = nil
    }

    // MARK: authorised

    private func authorised() {
        disarmStep()
        passwordTried = false
        strokeMac = pen.macAddress
        if !pen.macAddress.isEmpty { mac = PenRecord.normalise(pen.macAddress) }
        let version = pen.requestPenVersionInfo()
        firmware = version?.firmwareVersion ?? ""
        if name.isEmpty {
            name = [version?.deviceName, version?.subName].compactMap { $0 }.first { !$0.isEmpty } ?? "Neo smartpen"
        }
        state = .ready
        powerWriteAttempted = false
        Log.info("authorised: \(name) [\(mac)] fw \(firmware)")
        onAuthorised?(self)
        // The session may have let the pen go: an unknown pen that turned up after adding was
        // cancelled. Nothing more is said to a pen that is leaving.
        guard state == .ready else { return }
        pen.requestSetPenTime()
        pen.requestPenSettingInfo()
        pen.requestUsingAllNote()
        settingTimer?.invalidate()
        settingTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            self?.pen.requestPenSettingInfo()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.startDrain() }
    }

    /// Called by the session for a pen it will not keep. Stops everything before the link drops.
    func reject() {
        disarmStep()
        state = .connecting
        pen.disConnect()
    }

    private func handleSetting(_ s: PenSettingStruct) {
        setting = s
        onChange?()
        Log.info("\(name) status: battery \(s.battLevel)%\(s.charging == .On ? " (charging)" : ""), memory \(s.memoryUsed)% used")
        Log.info("\(name) power: auto-off \(s.autoPwrOffTime) min, auto-on-by-tip \(s.usePenTipOnOff), cap-power-off \(s.usePenCapOff), offline-save \(s.offlineOnOff), hover \(s.useHover), beep \(s.beepOnOff)")
        applyPowerSettings(s)
        if s.offlineOnOff == .Off {
            notifier.post(Notice(key: key("offline-save-off"), title: "\(name) is not storing notes offline",
                                 body: "Anything written away from this Mac would be lost. Turning it back on now."))
            pen.requestSetPenOfflineSave(.On)
        }
        if Int(s.battLevel) <= config.lowBatteryPercent && s.charging == .Off {
            notifier.post(Notice(key: key("battery"), title: "Pen battery at \(s.battLevel)%", body: "Charge \(name) soon."))
        } else {
            notifier.reset(key("battery"))
        }
        if Int(s.memoryUsed) >= config.memoryWarnPercent {
            notifier.post(Notice(key: key("memory"), title: "Pen memory \(s.memoryUsed)% full",
                                 body: "Keep \(name) near this Mac so it can be drained."))
        } else {
            notifier.reset(key("memory"))
        }
    }

    /// Push the configured power settings onto the pen, but only the ones that differ, and only
    /// once per connection: the settings are read back afterwards, and a pen that kept its own
    /// values has refused them, so repeating the write would just loop.
    private func applyPowerSettings(_ s: PenSettingStruct) {
        let pen = self.pen
        var pending: [(String, () -> Void)] = []
        if let want = config.penAutoPowerOn, (s.usePenTipOnOff == .On) != want {
            pending.append(("auto-power-on=\(want)", { pen.requestSetPenAutoPowerOn(want ? .On : .Off) }))
        }
        if let want = config.penAutoPowerOffMinutes, Int(s.autoPwrOffTime) != want {
            pending.append(("auto-power-off=\(want)min", { pen.requestSetPenAutoPowerOffTime(UInt16(want)) }))
        }
        if let want = config.penCapPowerOff, (s.usePenCapOff == .On) != want {
            pending.append(("cap-power-off=\(want)", { pen.requestSetPenCapOff(want ? .On : .Off) }))
        }
        guard !pending.isEmpty else { return }
        let names = pending.map(\.0).joined(separator: ", ")

        if powerWriteAttempted {
            Log.warn("\(name) kept its own values after being asked for \(names); it does not accept these settings")
            notifier.post(Notice(key: key("power-settings-refused"), title: "Pen refused a settings change",
                                 body: "\(name) would not accept \(names). Its own values stay in force."))
            return
        }
        powerWriteAttempted = true
        Log.info("setting \(names) on \(name)")
        for (_, apply) in pending { apply() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            Log.info("reading pen settings back to check they took")
            self?.pen.requestPenSettingInfo()
        }
    }

    // MARK: offline drain

    private func startDrain() {
        guard state == .ready, draining == nil else { return }
        Log.info("requesting offline note list from \(name)")
        pen.requestOfflineNoteList()
        armStep(15) { [weak self] in
            guard let self, self.draining == nil else { return }
            Log.warn("no offline note list received from \(self.name); will retry on next connection")
            self.state = .ready
        }
    }

    private func drainNext() {
        disarmStep()
        guard let next = drainQueue.first else {
            draining = nil
            drain = nil
            drainTotal = 0
            state = .ready
            Log.info("offline memory of \(name) drained")
            return
        }
        drainQueue.removeFirst()
        draining = next
        drainedPages = []
        drainedStrokes = 0
        drainTotal = max(drainTotal, drainQueue.count + 1)
        drain = Drain(index: drainTotal - drainQueue.count, count: drainTotal, percent: 0)
        state = .draining(remaining: drainQueue.count + 1)
        Log.info("draining book s\(next.section)/o\(next.owner)/b\(next.note) from \(name)")
        pen.requestOfflineData(next.section, next.owner, next.note, false)
        armProgress()
    }

    private func armProgress() {
        armStep(60) { [weak self] in
            guard let self, let n = self.draining else { return }
            Log.warn("offline transfer stalled for book b\(n.note) on \(self.name)")
            self.notifier.post(Notice(key: self.key("drain-stalled"), title: "Pen sync stalled",
                                      body: "Transfer from \(self.name) stopped mid-way. It will be retried next time the pen connects."))
            self.draining = nil
            self.drainNext()
        }
    }

    private func noteDrained() {
        disarmStep()
        guard let note = draining else { return }
        let pages = Array(drainedPages)
        let strokes = drainedStrokes
        Log.info("book b\(note.note): \(strokes) stroke(s) on \(pages.count) page(s)")
        guard strokes > 0 else {
            draining = nil
            drainNext()
            return
        }
        coordinator.publish(pages: pages, reason: "offline drain of book \(note.note)") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if self.config.deleteFromPenAfterPublish, self.isConnected {
                    Log.info("deleting book b\(note.note) from \(self.name)")
                    self.pen.requestDeleteOfflineDataNote(note.section, note.owner, [note.note])
                    self.armStep(15) { [weak self] in
                        Log.warn("no delete confirmation; moving on")
                        self?.draining = nil
                        self?.drainNext()
                    }
                    return
                }
            case let .failure(error):
                Log.error("publish after drain failed, keeping data on pen: \(error)")
            }
            self.draining = nil
            self.drainNext()
        }
    }

    /// The link is gone. Whatever stroke was open is kept; everything in flight is dropped.
    func reset() {
        disarmStep()
        settingTimer?.invalidate()
        settingTimer = nil
        if let s = assembler.flush() { coordinator.ingestLive([s]) }
        assembler = StrokeAssembler()
        reportUnread()
        draining = nil
        drain = nil
        drainTotal = 0
        drainQueue = []
        state = .scanning
    }
}

extension PenConnection {
    /// Say what the pen could not read, once for the window it happened in.
    fileprivate func reportUnread() {
        unreadTimer?.invalidate()
        unreadTimer = nil
        guard let report = unread.take() else { return }
        Log.warn("\(name): \(report.line)")
        guard report.worthTelling else { return }
        notifier.post(Notice(key: key("unread-ink"), title: "\(displayName) could not read the paper",
                             body: "Some of what was just written did not reach the Mac and is not in pen "
                                 + "memory. Check the page in the viewer and write it again if it is missing."))
    }
}

// MARK: - PenDelegate

extension PenConnection: PenDelegate {
    func penData(_ sender: PenController, _ dot: Dot) {
        DispatchQueue.main.async { [self] in
            lastDot = Date()
            let ctx = StrokeAssembler.Context(tip: SDKMapping.tip(dot.penTipType), color: SDKMapping.hex(dot.penTipColor),
                                              penMac: strokeMac, firmware: firmware)
            let page = SDKMapping.page(dot.pageInfo)
            let sample = SDKMapping.sample(dot)
            let event = SDKMapping.event(dot.dotType)
            onDot?(page, sample, event)
            if let stroke = assembler.feed(event: event, page: page, sample: sample,
                                           timeMs: dot.time, context: ctx) {
                coordinator.ingestLive([stroke])
            }
        }
    }

    func hoverData(_ sender: PenController, _ dot: Dot) {}

    func penMessage(_ sender: PenController, _ msg: PenMessage) {
        DispatchQueue.main.async { [self] in handle(msg) }
    }

    private func handle(_ msg: PenMessage) {
        switch msg {
        case .PEN_AUTHORIZED:
            authorised()
        case let .PEN_PASSWORD_REQUEST(req):
            guard req.status == .NeedPassword else { return }
            if let pin = config.penPassword, !passwordTried {
                passwordTried = true
                Log.info("\(displayName) asked for PIN; sending configured one (\(req.retryCount)/\(req.resetCount) attempts used)")
                pen.requestComparePassword(pin)
            } else {
                notifier.post(Notice(key: key("password"), title: "Pen needs a PIN",
                                     body: "Set penPassword in \(configURL.path) or remove the PIN in the pen's own app. Not retrying, since repeated failures reset the pen."))
                pen.disConnect()
            }
        case let .PEN_SETTING_INFO(s):
            handleSetting(s)
        case let .PEN_SETUP_SUCCESS(type):
            Log.info("\(name) accepted setting: \(type)")
        case let .PEN_SETUP_FAILURE(code):
            Log.warn("\(name) rejected a setting: \(code)")
        case let .EVENT_LOW_BATTERY(pct):
            notifier.post(Notice(key: key("battery"), title: "Pen battery at \(pct)%", body: "Charge \(displayName) soon."))
        case let .EVENT_POWER_OFF(reason):
            Log.info("\(name) powered off: \(reason)")
        case .PEN_CONNECTION_FAILURE_BTDUPLICATE:
            notifier.post(Notice(key: key("duplicate"), title: "Pen is connected elsewhere",
                                 body: "\(displayName) is already connected to another device. Disconnect it there to sync here."))
        case let .OFFLINE_DATA_NOTE_LIST(list):
            drainQueue = list.notes.map { Note(section: $0.section, owner: $0.owner, note: $0.note) }
            Log.info("offline memory of \(name) holds \(drainQueue.count) book(s)")
            drainNext()
        case .OFFLINE_DATA_SEND_START:
            armProgress()
        case let .OFFLINE_DATA_SEND_STATUS(pct):
            armProgress()
            if let d = drain { drain = Drain(index: d.index, count: d.count, percent: min(100, Int(pct))) }
            if pct >= 100 { noteDrained() }
        case let .OFFLINE_DATA_SEND_SUCCESS(data):
            let strokes = SDKMapping.strokes(from: data, penMac: strokeMac, firmware: firmware)
            drainedStrokes += strokes.count
            drainedPages.formUnion(coordinator.ingestOffline(strokes))
        case .OFFLINE_DATA_SEND_FAILURE:
            Log.error("offline transfer failed for book \(draining.map { "b\($0.note)" } ?? "?") on \(name)")
            notifier.post(Notice(key: key("drain-failed"), title: "Pen sync failed",
                                 body: "Transfer from \(displayName) failed. Data stays on the pen and will be retried."))
            draining = nil
            drainNext()
        case .OFFLINE_DATA_NOTE_DELETE_RES:
            Log.info("\(name) confirmed deletion")
            draining = nil
            drainNext()
        case let .PEN_PACKET_ERROR(err):
            Log.warn("packet error: \(err)")
        case let .EVENT_DOT_ERROR(err):
            Log.debug("dot error: \(err)")
            if unread.record(code: err.code) {
                unreadTimer = Timer.scheduledTimer(withTimeInterval: UnreadInk.window, repeats: false) { [weak self] _ in
                    self?.reportUnread()
                }
            }
        default:
            Log.debug("pen message: \(msg)")
        }
    }
}
