import AppKit
import CoreBluetooth
import Foundation
import NISDK3
import OpenSmartPenCore
import OpenSmartPenUI

/// Finds pens and decides which ones to keep. Scans whenever a paired pen is missing or a new one
/// is being added, connects to one pen at a time, and hands each connected pen to a
/// `PenConnection` of its own — so every paired pen can be connected, writing and draining at once.
/// All SDK callbacks are marshalled onto the main queue.
final class PenSession: NSObject {
    var onChange: (() -> Void)?
    /// Every dot as it arrives, before assembly, from whichever pen. The live view draws from
    /// this; the assembler only emits a stroke on pen-up, which is a whole word too late to watch.
    var onDot: ((PageID, DotSample, DotEvent) -> Void)?

    private(set) var bluetoothOff = false { didSet { if bluetoothOff != oldValue { onChange?() } } }
    /// Looking for a new pen, after "Add pen…" in Settings. Stops by itself after a while, so a
    /// pen switched on next week is not paired because somebody once opened the dialog.
    private(set) var adding = false { didSet { if adding != oldValue { onChange?() } } }

    private var config: Config
    private let configURL: URL
    private let coordinator: SyncCoordinator
    private let notifier: DedupingNotifier

    /// Every pen Bluetooth has linked, keyed by peripheral, whether or not it has authorised yet.
    private var links: [UUID: PenConnection] = [:]
    /// The one pen being linked right now. One at a time, because a fresh scan empties the SDK's
    /// list of what it has seen, and that list is where a pen's MAC is found when it connects.
    private var connecting: (peripheral: CBPeripheral, name: String, mac: String)?
    private var connectTimer: Timer?
    /// The Bluetooth link being made, timed for telemetry: from the first call to the link.
    private var connectSpan: TelemetrySpan?
    private var scanning = false
    private var scanTimer: Timer?
    private var addingTimer: Timer?
    /// How long "Add pen…" keeps looking.
    private static let addingWindow: TimeInterval = 120

    /// From the Mac going to sleep until a person wakes it. No pen is connected in between.
    ///
    /// A sleeping Mac's Bluetooth chip keeps a pen's link open, and macOS tells the app only that
    /// Bluetooth is off. The pen, still linked, sends what you write as live strokes — it stores
    /// nothing, because as far as it knows it is connected — and the strokes wake the Mac and
    /// reach nobody. A café meeting written with the lid shut was lost this way on 2026-10-07
    /// ("AP wakeup by LE Data bundleID=org.opensmartpen.app" in bluetoothd's log). Let go of every pen
    /// before sleep and the pen keeps its own copy, which is drained on wake like any other.
    /// Background wakes in the night must not reconnect, or the next sleep is the same trap.
    private(set) var systemAsleep = false

    /// When Bluetooth was first seen unavailable, and whether we have said so. Together these keep
    /// the startup flicker quiet and stop a persistent fault repeating on every scan tick.
    private var bluetoothOffSince: Date?
    private var reportedBluetoothProblem = false
    /// Ink hexes from the notes repo, for the LED. Read once; the file changes rarely.
    private var palette = Palette()

    init(config: Config, configURL: URL, coordinator: SyncCoordinator, notifier: DedupingNotifier) {
        self.config = config
        self.configURL = configURL
        self.coordinator = coordinator
        self.notifier = notifier
        super.init()
        palette = Palette.load(root: config.dataURL)
        // The pen cannot be told the ink colour, but it can acknowledge the choice. This is the
        // answer to the objection that a mode set on paper is invisible once set — though only at
        // the moment of tapping: the A1 sleeps after five minutes and the LED goes with it, so the
        // LED is the acknowledgement and the panel is the indicator.
        coordinator.modeLog?.onChange = { [weak self] ink, _ in self?.showOnLED(ink) }
    }

    /// Put the chosen ink on every connected pen's LED, as near as its eight fixed colours allow.
    /// An ink with no measured hex leaves the LEDs alone rather than guessing at it.
    private func showOnLED(_ ink: InkColor) {
        guard let rgb = palette.components(for: ink) else { return }
        for connection in links.values { connection.showOnLED(rgb) }
    }

    /// With no pen paired at all, the first pen seen is paired — the app works with no setup.
    /// After that a new pen is only taken while somebody is adding one.
    private var pairingOpen: Bool { adding || (autoPair && config.pairedPens.isEmpty) }
    /// Off once a pen has been forgotten in this launch. Forgetting the last pen empties the list,
    /// and without this the pen just forgotten would be paired again the moment it reconnects.
    private var autoPair = true

    var isAnyConnected: Bool { links.values.contains { $0.isConnected } }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.willSleep()
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.didWake()
        }
        PenFinder.shared.delegate = self
        scanTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.scanIfNeeded() }
        scanIfNeeded()
    }

    /// Pair the next unknown pen that turns up.
    func addPen() {
        adding = true
        Log.info("looking for a new pen to pair")
        addingTimer?.invalidate()
        addingTimer = Timer.scheduledTimer(withTimeInterval: Self.addingWindow, repeats: false) { [weak self] _ in
            guard let self, self.adding else { return }
            Log.info("no new pen found; stopped looking")
            Telemetry.event("pen.add_timed_out")
            self.adding = false
            self.scanIfNeeded()
        }
        // A pen already switched on was seen by this scan and ignored, and it is not reported
        // twice. Starting the scan again is what lets it be seen as a candidate.
        restartScan()
    }

    func cancelAdding() {
        addingTimer?.invalidate()
        addingTimer = nil
        adding = false
        scanIfNeeded()
    }

    /// Stop accepting a pen. Its `pens/` record stays: strokes it already wrote still name it.
    func forgetPen(mac: String) {
        let mac = PenRecord.normalise(mac)
        guard !mac.isEmpty else { return }
        let gone = links.values.filter { $0.mac == mac }
        config.pairedPens.removeAll { pen in
            pen.mac == mac || gone.contains { $0.peripheral.identifier.uuidString == pen.peripheralId }
        }
        autoPair = false
        savePairedPens()
        Log.info("forgot pen \(mac)")
        Telemetry.event("pen.forgotten", ["pen.mac": .string(mac), "pens.paired": .int(config.pairedPens.count)])
        for connection in gone { connection.disconnect() }
        onChange?()
    }

    private func willSleep() {
        Log.info("Mac is going to sleep; letting \(links.count) pen(s) go so they store what is written")
        Telemetry.event("system.sleep", ["pens.connected": .int(links.values.filter(\.isConnected).count)])
        letGo()
    }

    /// Before the app restarts itself for an update. The same reason as before sleep: a pen with
    /// no link stores what is written, and the app that starts next copies it from pen memory.
    /// Nothing connects again in this process.
    func letGoForRestart() {
        Log.info("the app is about to restart; letting \(links.count) pen(s) go so they store what is written")
        letGo()
    }

    private func letGo() {
        systemAsleep = true
        if scanning {
            PenFinder.shared.scanStop()
            scanning = false
        }
        // Sent now, not after the SDK's half-second courtesy delay: by then the Mac is asleep.
        for connection in links.values { connection.disconnect() }
        if let p = connecting { PenFinder.shared.disConnect(p.peripheral) }
    }

    private func didWake() {
        systemAsleep = false
        Log.info("Mac woke; looking for pens")
        Telemetry.event("system.wake")
        scanIfNeeded()
    }

    func requestSettingRefresh() {
        for connection in links.values where connection.isConnected { connection.requestSettingRefresh() }
    }

    // MARK: scanning and connecting

    /// Whether this launch has already put the permission question to macOS.
    private var askedForBluetooth = false

    /// A paired pen that is not linked. While there is one, the scan runs.
    private var missingPairedPen: Bool {
        config.pairedPens.contains { pen in
            !links.values.contains { c in
                (!pen.mac.isEmpty && c.mac == pen.mac) || c.peripheral.identifier.uuidString == pen.peripheralId
            }
        }
    }

    private func restartScan() {
        if scanning {
            PenFinder.shared.scanStop()
            scanning = false
        }
        scanIfNeeded()
    }

    private func scanIfNeeded() {
        guard connecting == nil, !systemAsleep else { return }
        guard PenFinder.shared.bluetoothOn else {
            // macOS asks for Bluetooth when an app uses Bluetooth, and not before. Waiting for a
            // grant we never request is therefore a deadlock, and a silent one: the radio is on,
            // the app says it is waiting for Bluetooth, and no dialog ever appears because nothing
            // ever scanned. So while the answer is "not asked yet", scan once and let the question
            // be put. It is asked once per launch, not once per tick, because a person who has
            // said no should not be asked again every five seconds.
            if CBCentralManager.authorization == .notDetermined, !askedForBluetooth {
                askedForBluetooth = true
                Log.info("no Bluetooth grant yet; scanning once so macOS asks for one")
                PenFinder.shared.scan(0)
                return
            }
            // CoreBluetooth reports `.unknown` for a moment after launch, before it settles on
            // powered-on. Complaining on the first tick would therefore announce that the radio is
            // switched off every single start, about a radio that is fine — which is the same kind
            // of confident wrong answer this diagnosis exists to stop. Wait for it to persist past
            // one scan tick; a real fault easily outlives that, a wakeup never does.
            let since = bluetoothOffSince ?? Date()
            bluetoothOffSince = since
            if !reportedBluetoothProblem, Date().timeIntervalSince(since) >= 5 {
                reportedBluetoothProblem = true
                let problem = Self.bluetoothProblem()
                Log.warn(problem)
                Telemetry.event("bluetooth.unavailable",
                                ["bluetooth.authorization": .string(Self.authorizationName)], level: .warn)
                // The panel and the tooltip can only say "Bluetooth off", which is a lie when the
                // radio is on and the real fault is permission we were never given — and it is a
                // lie that costs an afternoon, because switching Bluetooth off and on again will
                // never fix it. A missing grant also never repairs itself, so it is exactly the
                // kind of thing this app is supposed to speak up about. Deduped by the notifier.
                if CBCentralManager.authorization != .allowedAlways {
                    notifier.post(Notice(key: "bluetooth-permission",
                                         title: "Open Smart Pen cannot use Bluetooth",
                                         body: problem))
                }
            }
            bluetoothOff = true
            return
        }
        // Bluetooth is back, so a later outage is news again.
        bluetoothOffSince = nil
        reportedBluetoothProblem = false
        bluetoothOff = false
        let wanted = pairingOpen || missingPairedPen
        if wanted, !scanning {
            scanning = true
            PenFinder.shared.scan(0)
            Log.debug("scanning for pens")
        } else if !wanted, scanning {
            // Every paired pen is here. Nothing left to look for.
            PenFinder.shared.scanStop()
            scanning = false
        }
    }

    /// Why there is no Bluetooth, in words that say what to do about it.
    ///
    /// The SDK reports one flag for two unrelated situations, and they need opposite fixes: a radio
    /// that is switched off, and permission this app was never given. Guessing wrong costs an hour
    /// of staring at a radio that is already on, because the app just says it is "waiting".
    ///
    /// The grant is tied to the code signature as well as the bundle identifier, and an ad-hoc
    /// signature changes with every build, so it is lost on a rename *and* on a plain rebuild.
    static func bluetoothProblem() -> String {
        switch CBCentralManager.authorization {
        case .notDetermined:
            return "Bluetooth permission has not been asked for yet. macOS only prompts an app "
                 + "launched from the Finder, so open Open Smart Pen.app once by hand; the LaunchAgent "
                 + "inherits the grant afterwards."
        case .restricted, .denied:
            return "Open Smart Pen is not allowed to use Bluetooth. Allow it in System Settings → "
                 + "Privacy & Security → Bluetooth, then restart it."
        case .allowedAlways:
            return "Bluetooth is switched off; waiting for it."
        @unknown default:
            return "Bluetooth is unavailable for an unknown reason; waiting."
        }
    }

    /// The Bluetooth grant, as one word for telemetry.
    private static var authorizationName: String {
        switch CBCentralManager.authorization {
        case .notDetermined: return "not asked"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .allowedAlways: return "allowed"
        @unknown default: return "unknown"
        }
    }

    /// Whether a pen just seen is one to connect to: a paired pen, or any pen while pairing is
    /// open — but only one new pen at a time, so two strangers are never both taken.
    private func wants(_ peripheral: CBPeripheral, _ ad: PenAdvertisementStruct) -> Bool {
        if config.isPaired(mac: ad.mac, peripheralId: peripheral.identifier.uuidString) { return true }
        guard pairingOpen else { return false }
        return !links.values.contains { !isPaired($0) }
    }

    private func isPaired(_ c: PenConnection) -> Bool {
        config.isPaired(mac: c.mac, peripheralId: c.peripheral.identifier.uuidString)
    }

    private func connect(_ peripheral: CBPeripheral, _ ad: PenAdvertisementStruct) {
        PenFinder.shared.scanStop()
        scanning = false
        let name = peripheral.name ?? (ad.subName.isEmpty ? "" : ad.subName)
        connecting = (peripheral, name, ad.mac)
        Log.info("connecting to \(name.isEmpty ? "pen" : name) [\(ad.mac)]")
        // Only a pen this Mac has decided to take is ever named: a paired one, or the one being
        // added. A stranger's pen that is merely seen is never reported.
        connectSpan = Telemetry.begin("pen.connect", [
            "pen.mac": .string(PenRecord.normalise(ad.mac)),
            "pen.paired": .bool(config.isPaired(mac: ad.mac, peripheralId: peripheral.identifier.uuidString)),
        ])
        PenFinder.shared.connectPeripheral(peripheral)
        onChange?()
        connectTimer?.invalidate()
        connectTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self, let p = self.connecting, p.peripheral.identifier == peripheral.identifier else { return }
            Log.warn("connect timed out")
            self.endConnect("timed out")
            PenFinder.shared.disConnect(p.peripheral)
            self.connecting = nil
            self.onChange?()
            self.scanIfNeeded()
        }
    }

    private func endConnect(_ error: String? = nil) {
        connectSpan?.end(error: error)
        connectSpan = nil
    }

    /// The pen has accepted us. A new pen is paired here, and an unknown pen that is no longer
    /// wanted — adding was cancelled while it connected — is let go.
    private func authorised(_ connection: PenConnection) {
        let id = connection.peripheral.identifier.uuidString
        if let i = config.pairedPens.firstIndex(where: {
            (!connection.mac.isEmpty && $0.mac == connection.mac) || $0.peripheralId == id
        }) {
            // A known pen. Fill in whichever half of its identity was missing.
            let updated = PairedPen(mac: connection.mac.isEmpty ? config.pairedPens[i].mac : connection.mac,
                                    peripheralId: id)
            if updated != config.pairedPens[i] {
                config.pairedPens[i] = updated
                savePairedPens()
            }
        } else if pairingOpen {
            Telemetry.event("pen.paired", ["pen.mac": .string(connection.mac),
                                           "pen.pairing": .string(adding ? "added" : "first pen"),
                                           "pens.paired": .int(config.pairedPens.count + 1)])
            config.pairedPens.append(PairedPen(mac: connection.mac, peripheralId: id))
            savePairedPens()
            addingTimer?.invalidate()
            adding = false
            Log.info("paired \(connection.name) [\(connection.mac)]")
            notifier.post(Notice(key: "paired-\(connection.mac)", title: "Open Smart Pen paired with \(connection.name)",
                                 body: "Notes from it will be synced automatically from now on."))
        } else {
            Log.info("\(connection.name) is not paired and no pen is being added; letting it go")
            Telemetry.event("pen.rejected")
            connection.reject()
            return
        }
        onChange?()
        scanIfNeeded()
    }

    /// Write back only the field this object owns: which pens are paired.
    ///
    /// Two things save this file — the settings window and this — and each held its own copy of
    /// the whole config. Whichever wrote last won, so pairing a pen quietly threw away a
    /// setting somebody had just typed in. The file is re-read here so that everything this object
    /// knows nothing about survives it.
    private func savePairedPens() {
        do {
            var latest = (try? Config.loadOrCreate(at: configURL)) ?? config
            latest.pairedPens = config.pairedPens
            try latest.save(to: configURL)
        } catch {
            Log.error("saving config failed: \(error)")
        }
    }

    private func dropConnection(_ peripheral: CBPeripheral) {
        if connecting?.peripheral.identifier == peripheral.identifier {
            connectTimer?.invalidate()
            connecting = nil
            endConnect("dropped")
        }
        links.removeValue(forKey: peripheral.identifier)?.reset()
        onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.scanIfNeeded() }
    }
}

// MARK: - PenFinderDelegate

extension PenSession: PenFinderDelegate {
    func discoverPen(_ peripheral: CBPeripheral, _ pen: PenAdvertisementStruct, _ rssi: Int) {
        DispatchQueue.main.async { [self] in
            guard connecting == nil, !systemAsleep, links[peripheral.identifier] == nil else { return }
            Log.debug("found \(peripheral.name ?? "?") mac=\(pen.mac) rssi=\(rssi)")
            guard wants(peripheral, pen) else { return }
            connect(peripheral, pen)
        }
    }

    func scanStop() {
        DispatchQueue.main.async { [self] in scanning = false }
    }

    func didConnect(_ pencontroller: PenController) {
        DispatchQueue.main.async { [self] in
            guard let peripheral = pencontroller.peripheral else { return }
            if systemAsleep {
                // A connect that was already under way when sleep began. Not now.
                connectTimer?.invalidate()
                connecting = nil
                endConnect("the Mac went to sleep")
                pencontroller.disConnect()
                return
            }
            let pending = connecting?.peripheral.identifier == peripheral.identifier ? connecting : nil
            connectTimer?.invalidate()
            connecting = nil
            endConnect()
            let mac = pencontroller.macAddress.isEmpty ? (pending?.mac ?? "") : pencontroller.macAddress
            let connection = PenConnection(pen: pencontroller, peripheral: peripheral,
                                           name: pending?.name ?? peripheral.name ?? "", mac: mac,
                                           config: config, configURL: configURL,
                                           coordinator: coordinator, notifier: notifier)
            connection.onChange = { [weak self] in self?.onChange?() }
            connection.onDot = { [weak self] page, dot, event in self?.onDot?(page, dot, event) }
            connection.onAuthorised = { [weak self] c in self?.authorised(c) }
            links[peripheral.identifier] = connection
            connection.start()
            onChange?()
            // Another paired pen may be waiting its turn.
            scanIfNeeded()
        }
    }

    func didFailToConnect(_ peripheral: CBPeripheral, _ error: Error?) {
        DispatchQueue.main.async { [self] in
            Log.warn("connect failed: \(error?.localizedDescription ?? "unknown")")
            endConnect(error?.localizedDescription ?? "failed")
            dropConnection(peripheral)
        }
    }

    func didDisconnect(_ central: CBCentralManager, _ peripheral: CBPeripheral?, _ error: Error?) {
        DispatchQueue.main.async { [self] in
            guard let peripheral else {
                // Bluetooth itself went away, and every pen with it.
                Log.warn("bluetooth powered off")
                scanning = false
                connectTimer?.invalidate()
                connecting = nil
                endConnect("Bluetooth went off")
                for connection in links.values { connection.reset() }
                links = [:]
                onChange?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.scanIfNeeded() }
                return
            }
            let name = links[peripheral.identifier]?.name ?? peripheral.name ?? "pen"
            Log.info("\(name) disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
            // Only for a pen that had been accepted. One that was let go was never ours to name.
            if let link = links[peripheral.identifier], link.wasAuthorised {
                var attributes: [String: TelemetryValue] = [
                    "pen.mac": .string(link.mac),
                    "pen.connected_seconds": .int(Int(Date().timeIntervalSince(link.linkedAt))),
                    "pen.disconnect_error": .bool(error != nil),
                ]
                if systemAsleep { attributes["pen.disconnect_reason"] = "sleep" }
                Telemetry.event("pen.disconnected", attributes)
            }
            dropConnection(peripheral)
        }
    }
}

// MARK: - PenLink

/// The UI's view of the pens. Everything the SDK reports is turned into plain numbers here, so
/// that `OpenSmartPenUI` builds and runs with no pen and no SDK behind it.
extension PenSession: PenLink {
    var isAdding: Bool { adding }

    var pairedMacs: [String] { config.pairedPens.map(\.mac).filter { !$0.isEmpty } }

    var connections: [PenConnectionInfo] {
        var list = links.values.map(\.info)
        if let p = connecting {
            list.append(PenConnectionInfo(mac: PenRecord.normalise(p.mac), name: p.name, state: .connecting,
                                          drain: nil, reading: nil, lastDot: nil))
        }
        return list
    }
}
