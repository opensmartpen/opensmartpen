import CoreBluetooth
import Foundation
import NISDK3
import PenBridgeCore

/// Keeps one pen connected and drained. Scans whenever no pen is connected, connects to the paired pen
/// (or pairs with the first pen seen), authorises, drains offline memory notebook by notebook, and
/// forwards live strokes. All SDK callbacks are marshalled onto the main queue.
final class PenSession: NSObject {
    enum State: Equatable {
        case bluetoothOff
        case scanning
        case connecting
        case authorizing
        case ready
        case draining(remaining: Int)
    }

    private(set) var state: State = .scanning { didSet { if state != oldValue { onChange?() } } }
    private(set) var setting: PenSettingStruct?
    private(set) var penName = ""
    var onChange: (() -> Void)?

    private var config: Config
    private let configURL: URL
    private let coordinator: SyncCoordinator
    private let notifier: DedupingNotifier

    private var pen: PenController?
    private var connecting: CBPeripheral?
    private var scanning = false
    private var scanTimer: Timer?
    private var stepTimer: Timer?
    private var settingTimer: Timer?
    private var passwordTried = false

    private var assembler = StrokeAssembler()
    private var penMac = ""
    private var firmware = ""

    private struct Note { let section: UInt8; let owner: UInt32; let note: UInt32 }
    private var drainQueue: [Note] = []
    private var draining: Note?
    private var drainedPages: Set<PageID> = []
    private var drainedStrokes = 0

    init(config: Config, configURL: URL, coordinator: SyncCoordinator, notifier: DedupingNotifier) {
        self.config = config
        self.configURL = configURL
        self.coordinator = coordinator
        self.notifier = notifier
        super.init()
    }

    var isPaired: Bool { config.penMac != nil || config.penPeripheralId != nil }

    func start() {
        PenFinder.shared.delegate = self
        scanTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.scanIfNeeded() }
        scanIfNeeded()
    }

    /// Forget the paired pen and pair with the next one seen.
    func forgetPen() {
        config.penMac = nil
        config.penPeripheralId = nil
        saveConfig()
        pen?.disConnect()
        notifier.post(Notice(key: "pairing", title: "PenBridge is looking for a pen",
                             body: "Turn on the pen you want to use. The first pen found will be paired."))
    }

    func requestSettingRefresh() { pen?.requestPenSettingInfo() }

    // MARK: scanning and connecting

    private func scanIfNeeded() {
        guard pen == nil, connecting == nil else { return }
        guard PenFinder.shared.bluetoothOn else {
            if state != .bluetoothOff {
                Log.warn("bluetooth is off or PenBridge is not allowed to use it (System Settings → Privacy & Security → Bluetooth); waiting")
            }
            state = .bluetoothOff
            return
        }
        state = .scanning
        if !scanning {
            scanning = true
            PenFinder.shared.scan(0)
            Log.debug("scanning for pens")
        }
    }

    private func matches(_ peripheral: CBPeripheral, _ ad: PenAdvertisementStruct) -> Bool {
        if !isPaired { return true }
        if let mac = config.penMac, !mac.isEmpty, mac.caseInsensitiveCompare(ad.mac) == .orderedSame { return true }
        if let id = config.penPeripheralId, id == peripheral.identifier.uuidString { return true }
        return false
    }

    private func connect(_ peripheral: CBPeripheral, _ ad: PenAdvertisementStruct) {
        PenFinder.shared.scanStop()
        scanning = false
        connecting = peripheral
        penName = peripheral.name ?? (ad.subName.isEmpty ? "" : ad.subName)
        state = .connecting
        Log.info("connecting to \(penName.isEmpty ? "pen" : penName) [\(ad.mac)]")
        PenFinder.shared.connectPeripheral(peripheral)
        armStep(20) { [weak self] in
            guard let self, self.pen == nil, let p = self.connecting else { return }
            Log.warn("connect timed out")
            PenFinder.shared.disConnect(p)
            self.connecting = nil
            self.scanIfNeeded()
        }
    }

    private func armStep(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        stepTimer?.invalidate()
        stepTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in block() }
    }

    private func disarmStep() {
        stepTimer?.invalidate()
        stepTimer = nil
    }

    private func saveConfig() {
        do { try config.save(to: configURL) } catch { Log.error("saving config failed: \(error)") }
    }

    // MARK: authorised

    private func authorised() {
        guard let pen else { return }
        disarmStep()
        passwordTried = false
        penMac = pen.macAddress
        let version = pen.requestPenVersionInfo()
        firmware = version?.firmwareVersion ?? ""
        if penName.isEmpty {
            penName = [version?.deviceName, version?.subName].compactMap { $0 }.first { !$0.isEmpty } ?? "Neo smartpen"
        }
        if config.penMac != pen.macAddress || config.penPeripheralId != pen.peripheral?.identifier.uuidString {
            let firstPairing = !isPaired
            config.penMac = pen.macAddress
            config.penPeripheralId = pen.peripheral?.identifier.uuidString
            saveConfig()
            if firstPairing {
                notifier.post(Notice(key: "paired", title: "PenBridge paired with \(penName)",
                                     body: "Notes will be synced automatically from now on."))
            }
        }
        state = .ready
        Log.info("authorised: \(penName) fw \(firmware)")
        pen.requestSetPenTime()
        pen.requestPenSettingInfo()
        pen.requestUsingAllNote()
        settingTimer?.invalidate()
        settingTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            self?.pen?.requestPenSettingInfo()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.startDrain() }
    }

    private func handleSetting(_ s: PenSettingStruct) {
        setting = s
        onChange?()
        Log.info("pen status: battery \(s.battLevel)%\(s.charging == .On ? " (charging)" : ""), memory \(s.memoryUsed)% used, auto-off \(s.autoPwrOffTime) min")
        if Int(s.battLevel) <= config.lowBatteryPercent && s.charging == .Off {
            notifier.post(Notice(key: "battery", title: "Pen battery at \(s.battLevel)%", body: "Charge \(penName) soon."))
        } else {
            notifier.reset("battery")
        }
        if Int(s.memoryUsed) >= config.memoryWarnPercent {
            notifier.post(Notice(key: "memory", title: "Pen memory \(s.memoryUsed)% full",
                                 body: "Keep the pen near this Mac so it can be drained."))
        } else {
            notifier.reset("memory")
        }
    }

    // MARK: offline drain

    private func startDrain() {
        guard let pen, draining == nil else { return }
        Log.info("requesting offline note list")
        pen.requestOfflineNoteList()
        armStep(15) { [weak self] in
            guard let self, self.draining == nil else { return }
            Log.warn("no offline note list received; will retry on next connection")
            self.state = .ready
        }
    }

    private func drainNext() {
        disarmStep()
        guard let pen else { return }
        guard let next = drainQueue.first else {
            draining = nil
            state = .ready
            Log.info("offline memory drained")
            return
        }
        drainQueue.removeFirst()
        draining = next
        drainedPages = []
        drainedStrokes = 0
        state = .draining(remaining: drainQueue.count + 1)
        Log.info("draining book s\(next.section)/o\(next.owner)/b\(next.note)")
        pen.requestOfflineData(next.section, next.owner, next.note, false)
        armProgress()
    }

    private func armProgress() {
        armStep(60) { [weak self] in
            guard let self, let n = self.draining else { return }
            Log.warn("offline transfer stalled for book b\(n.note)")
            self.notifier.post(Notice(key: "drain-stalled", title: "Pen sync stalled",
                                      body: "Transfer from \(self.penName) stopped mid-way. It will be retried next time the pen connects."))
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
                if self.config.deleteFromPenAfterPublish, let pen = self.pen {
                    Log.info("deleting book b\(note.note) from pen")
                    pen.requestDeleteOfflineDataNote(note.section, note.owner, [note.note])
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

    private func resetConnection() {
        disarmStep()
        settingTimer?.invalidate()
        settingTimer = nil
        if let s = assembler.flush() { coordinator.ingestLive([s]) }
        assembler = StrokeAssembler()
        pen = nil
        connecting = nil
        draining = nil
        drainQueue = []
        setting = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.scanIfNeeded() }
    }
}

// MARK: - PenFinderDelegate

extension PenSession: PenFinderDelegate {
    func discoverPen(_ peripheral: CBPeripheral, _ pen: PenAdvertisementStruct, _ rssi: Int) {
        DispatchQueue.main.async { [self] in
            guard self.pen == nil, connecting == nil else { return }
            Log.debug("found \(peripheral.name ?? "?") mac=\(pen.mac) rssi=\(rssi)")
            guard matches(peripheral, pen) else { return }
            connect(peripheral, pen)
        }
    }

    func scanStop() {
        DispatchQueue.main.async { [self] in scanning = false }
    }

    func didConnect(_ pencontroller: PenController) {
        DispatchQueue.main.async { [self] in
            connecting = nil
            pen = pencontroller
            pencontroller.setPenDelegate(self)
            pencontroller.showSDKLog(config.sdkDebugLog)
            state = .authorizing
            armStep(20) { [weak self] in
                guard let self, self.state == .authorizing else { return }
                Log.warn("authorisation timed out; disconnecting")
                self.pen?.disConnect()
            }
        }
    }

    func didFailToConnect(_ peripheral: CBPeripheral, _ error: Error?) {
        DispatchQueue.main.async { [self] in
            Log.warn("connect failed: \(error?.localizedDescription ?? "unknown")")
            resetConnection()
        }
    }

    func didDisconnect(_ central: CBCentralManager, _ peripheral: CBPeripheral?, _ error: Error?) {
        DispatchQueue.main.async { [self] in
            if peripheral == nil && !PenFinder.shared.bluetoothOn {
                Log.warn("bluetooth powered off")
                scanning = false
            } else {
                Log.info("disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
            }
            resetConnection()
        }
    }
}

// MARK: - PenDelegate

extension PenSession: PenDelegate {
    func penData(_ sender: PenController, _ dot: Dot) {
        DispatchQueue.main.async { [self] in
            let ctx = StrokeAssembler.Context(tip: SDKMapping.tip(dot.penTipType), color: SDKMapping.hex(dot.penTipColor),
                                              penMac: penMac, firmware: firmware)
            if let stroke = assembler.feed(event: SDKMapping.event(dot.dotType), page: SDKMapping.page(dot.pageInfo),
                                           sample: SDKMapping.sample(dot), timeMs: dot.time, context: ctx) {
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
                Log.info("pen asked for PIN; sending configured one (\(req.retryCount)/\(req.resetCount) attempts used)")
                pen?.requestComparePassword(pin)
            } else {
                notifier.post(Notice(key: "password", title: "Pen needs a PIN",
                                     body: "Set penPassword in \(configURL.path) or remove the PIN in the pen's own app. Not retrying, since repeated failures reset the pen."))
                pen?.disConnect()
            }
        case let .PEN_SETTING_INFO(s):
            handleSetting(s)
        case let .EVENT_LOW_BATTERY(pct):
            notifier.post(Notice(key: "battery", title: "Pen battery at \(pct)%", body: "Charge \(penName) soon."))
        case let .EVENT_POWER_OFF(reason):
            Log.info("pen powered off: \(reason)")
        case .PEN_CONNECTION_FAILURE_BTDUPLICATE:
            notifier.post(Notice(key: "duplicate", title: "Pen is connected elsewhere",
                                 body: "\(penName) is already connected to another device. Disconnect it there to sync here."))
        case let .OFFLINE_DATA_NOTE_LIST(list):
            drainQueue = list.notes.map { Note(section: $0.section, owner: $0.owner, note: $0.note) }
            Log.info("offline memory holds \(drainQueue.count) book(s)")
            drainNext()
        case .OFFLINE_DATA_SEND_START:
            armProgress()
        case let .OFFLINE_DATA_SEND_STATUS(pct):
            armProgress()
            if pct >= 100 { noteDrained() }
        case let .OFFLINE_DATA_SEND_SUCCESS(data):
            let strokes = SDKMapping.strokes(from: data, penMac: penMac, firmware: firmware)
            drainedStrokes += strokes.count
            drainedPages.formUnion(coordinator.ingestOffline(strokes))
        case .OFFLINE_DATA_SEND_FAILURE:
            Log.error("offline transfer failed for book \(draining.map { "b\($0.note)" } ?? "?")")
            notifier.post(Notice(key: "drain-failed", title: "Pen sync failed",
                                 body: "Transfer from \(penName) failed. Data stays on the pen and will be retried."))
            draining = nil
            drainNext()
        case .OFFLINE_DATA_NOTE_DELETE_RES:
            Log.info("pen confirmed deletion")
            draining = nil
            drainNext()
        case let .PEN_PACKET_ERROR(err):
            Log.warn("packet error: \(err)")
        case let .EVENT_DOT_ERROR(err):
            Log.debug("dot error: \(err)")
        default:
            Log.debug("pen message: \(msg)")
        }
    }
}
