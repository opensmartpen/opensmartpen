import Foundation

/// User configuration, stored as JSON at ~/.config/brainio-pen/config.json.
/// Every field has a default so the app runs with no setup; the file is written on first launch.
public struct Config: Codable, Equatable {
    /// Where everything the pen captures is kept, and the readable files made from it.
    ///
    /// Outside the app on purpose, so the app can be deleted and installed again without taking
    /// the notes with it. `pen` rather than the bare `~/Brainio`, because there will be more
    /// Brainio products and none of them should be able to disturb this one (ADR-002).
    public var dataPath: String = "~/Brainio/pen"
    /// Where the notes were before ADR-002 moved them. Read from an older config file so the
    /// move can find them once; never written.
    public var legacyRepoPath: String?
    /// Seconds with no event at all from any pen before the waiting pages are uploaded. Short,
    /// because whatever reads the bucket should see a page soon after the pen is put down; long
    /// enough that a page in the middle of a sentence is not sent once per word.
    public var quietSeconds: Double = 30
    /// The pens this Mac accepts. Empty until the first pen is paired automatically; every pen
    /// after that is added in Settings, so a pen on the next desk is never taken by accident.
    /// An older config's single `penMac` and `penPeripheralId` are read into this list.
    public var pairedPens: [PairedPen] = []
    /// PIN for a password-protected pen. Nil means no PIN.
    public var penPassword: String?
    /// Delete a notebook from pen memory once its strokes are synced: uploaded when a bucket is
    /// connected, on this Mac's disk when none is.
    public var deleteFromPenAfterPublish: Bool = true
    /// The bucket everything is copied to. Empty until one is connected in Settings, and until
    /// then the notes simply stay on this Mac. The secret key is not here: it is in `s3-secret`
    /// beside this file (`S3Secret`).
    public var s3 = S3Settings()
    /// Pen power settings, applied on every connect when set. Nil leaves the pen's own value alone.
    /// `penAutoPowerOn` wakes the pen when the tip is pressed or the cap comes off, which is what
    /// stops strokes being lost to a sleeping pen. `penAutoPowerOffMinutes` is the inactivity timeout.
    /// `penCapPowerOff` powers the pen down when the cap goes on.
    public var penAutoPowerOn: Bool?
    public var penAutoPowerOffMinutes: Int?
    public var penCapPowerOff: Bool?

    /// Notebooks that are printed control surfaces rather than paper to write on, such as the
    /// colour strip that came with the LAMY pad. Taps on these are commands, not notes, so they
    /// are logged and discarded instead of being filed as pages.
    public var controlBooks: [String] = ["s3/o1013/b1"]

    /// Notify when battery falls to or below this percentage.
    public var lowBatteryPercent: Int = 20
    /// Notify when pen memory usage reaches this percentage.
    public var memoryWarnPercent: Int = 70
    /// Print the SDK's own protocol log.
    public var sdkDebugLog: Bool = false

    public init() {}

    /// Whether this pen is one of ours, by MAC or, when the advertisement carried no MAC, by the
    /// identifier CoreBluetooth gave it.
    public func isPaired(mac: String, peripheralId: String?) -> Bool {
        let mac = PenRecord.normalise(mac)
        return pairedPens.contains { pen in
            (!mac.isEmpty && pen.mac == mac) || (peripheralId != nil && pen.peripheralId == peripheralId)
        }
    }

    /// Missing keys take their defaults, so an older or hand-edited file keeps loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        dataPath = try c.decodeIfPresent(String.self, forKey: .dataPath) ?? d.dataPath
        legacyRepoPath = try c.decodeIfPresent(String.self, forKey: .repoPath)
        quietSeconds = try c.decodeIfPresent(Double.self, forKey: .quietSeconds) ?? d.quietSeconds
        if let list = try c.decodeIfPresent([PairedPen].self, forKey: .pairedPens) {
            pairedPens = list
        } else {
            let mac = try c.decodeIfPresent(String.self, forKey: .penMac)
            let id = try c.decodeIfPresent(String.self, forKey: .penPeripheralId)
            if mac != nil || id != nil { pairedPens = [PairedPen(mac: mac ?? "", peripheralId: id)] }
        }
        penPassword = try c.decodeIfPresent(String.self, forKey: .penPassword)
        deleteFromPenAfterPublish = try c.decodeIfPresent(Bool.self, forKey: .deleteFromPenAfterPublish) ?? d.deleteFromPenAfterPublish
        penAutoPowerOn = try c.decodeIfPresent(Bool.self, forKey: .penAutoPowerOn)
        penAutoPowerOffMinutes = try c.decodeIfPresent(Int.self, forKey: .penAutoPowerOffMinutes)
        penCapPowerOff = try c.decodeIfPresent(Bool.self, forKey: .penCapPowerOff)
        controlBooks = try c.decodeIfPresent([String].self, forKey: .controlBooks) ?? d.controlBooks
        s3 = try c.decodeIfPresent(S3Settings.self, forKey: .s3) ?? d.s3
        lowBatteryPercent = try c.decodeIfPresent(Int.self, forKey: .lowBatteryPercent) ?? d.lowBatteryPercent
        memoryWarnPercent = try c.decodeIfPresent(Int.self, forKey: .memoryWarnPercent) ?? d.memoryWarnPercent
        sdkDebugLog = try c.decodeIfPresent(Bool.self, forKey: .sdkDebugLog) ?? d.sdkDebugLog
    }

    /// The bucket to upload to, or nil when one is not connected. Asking for the secret here
    /// rather than storing it keeps one answer to "is this configured": every part, or none.
    public func s3Account(secret: String? = S3Secret.read()) -> S3Account? {
        S3Account(settings: s3, secret: secret)
    }

    public var dataURL: URL {
        URL(fileURLWithPath: (dataPath as NSString).expandingTildeInPath)
    }

    /// Where the notes were before ADR-002. An older config names it; a config written after the
    /// PenBridge rename but before ADR-002 may not, so the old default is checked as well — the
    /// notes are there either way, and finding them is what matters.
    public var legacyRepoURL: URL? {
        if let named = legacyRepoPath {
            return URL(fileURLWithPath: (named as NSString).expandingTildeInPath)
        }
        let old = URL(fileURLWithPath: ("~/BrainioPen/notes" as NSString).expandingTildeInPath)
        return FileManager.default.fileExists(atPath: old.path) ? old : nil
    }

    /// `repoPath`, `penMac` and `penPeripheralId` are decoded but never encoded, so adopting an
    /// old config does not carry the old shape forward once it has been read. Keys from before
    /// the bucket — the git push, the DAM agents, the wait in minutes — are not read at all, and
    /// fall out of the file the next time it is saved.
    private enum CodingKeys: String, CodingKey {
        case dataPath, repoPath, quietSeconds, pairedPens, penMac, penPeripheralId, penPassword
        case deleteFromPenAfterPublish, s3, penAutoPowerOn, penAutoPowerOffMinutes
        case penCapPowerOff, controlBooks, lowBatteryPercent, memoryWarnPercent, sdkDebugLog
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dataPath, forKey: .dataPath)
        try c.encode(quietSeconds, forKey: .quietSeconds)
        try c.encode(pairedPens, forKey: .pairedPens)
        try c.encodeIfPresent(penPassword, forKey: .penPassword)
        try c.encode(deleteFromPenAfterPublish, forKey: .deleteFromPenAfterPublish)
        if !s3.isEmpty { try c.encode(s3, forKey: .s3) }
        try c.encodeIfPresent(penAutoPowerOn, forKey: .penAutoPowerOn)
        try c.encodeIfPresent(penAutoPowerOffMinutes, forKey: .penAutoPowerOffMinutes)
        try c.encodeIfPresent(penCapPowerOff, forKey: .penCapPowerOff)
        try c.encode(controlBooks, forKey: .controlBooks)
        try c.encode(lowBatteryPercent, forKey: .lowBatteryPercent)
        try c.encode(memoryWarnPercent, forKey: .memoryWarnPercent)
        try c.encode(sdkDebugLog, forKey: .sdkDebugLog)
    }

    private static var configBase: URL {
        ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
    }

    public static var defaultLocation: URL {
        configBase.appendingPathComponent("brainio-pen/config.json")
    }

    /// Where the config lived while the app was called PenBridge.
    public static var legacyLocation: URL {
        configBase.appendingPathComponent("penbridge/config.json")
    }

    /// Adopt a PenBridge-era config directory, so the rename does not cost the paired pen.
    ///
    /// Everything beside `config.json` comes too — `pen-state.json` lives here, and a half-migrated
    /// directory would forget which pen was flat. It is *copied* rather than moved: an install
    /// still running on the old name keeps working, and nothing is destroyed by a first launch.
    ///
    /// The test is whether `config.json` is there, not whether the directory is. A build that ran
    /// once before the migration leaves the directory behind holding nothing but defaults, and
    /// refusing on that would drop the paired pen at exactly the moment someone upgrades. So files
    /// are copied one by one into whatever is already there, and anything already present wins —
    /// it was written under the new name, which makes it newer than what we are adopting.
    @discardableResult
    static func adoptLegacyDirectory(at url: URL = defaultLocation,
                                     legacy: URL = legacyLocation) -> Bool {
        let fm = FileManager.default
        let new = url.deletingLastPathComponent()
        let old = legacy.deletingLastPathComponent()
        guard !fm.fileExists(atPath: url.path),
              fm.fileExists(atPath: legacy.path) else { return false }
        do {
            try fm.createDirectory(at: new, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: old.path) {
                let target = new.appendingPathComponent(name)
                guard !fm.fileExists(atPath: target.path) else { continue }
                try fm.copyItem(at: old.appendingPathComponent(name), to: target)
            }
            Log.info("adopted config from \(old.path) — the app was called PenBridge there")
            return true
        } catch {
            Log.error("could not adopt config from \(old.path): \(error)")
            return false
        }
    }

    /// Load the config, creating the file with defaults when it does not exist.
    public static func loadOrCreate(at url: URL = defaultLocation) throws -> Config {
        let fm = FileManager.default
        // Only the real location adopts. A caller pointing somewhere else — a test, a second
        // profile — must not be handed the config of whatever lives in the home directory.
        let real = url == defaultLocation
        if real, !fm.fileExists(atPath: url.path) { adoptLegacyDirectory(at: url) }
        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let config = try decoder.decode(Config.self, from: data)
            // A config that is still every default, with a PenBridge-era one sitting next to it,
            // means adoption was skipped — the file was created by a launch that happened before
            // the old directory could be taken over. Nothing is lost yet, but the pen looks
            // unpaired and the fix is not guessable, so say it every launch until it is dealt with.
            if real, config == Config(), fm.fileExists(atPath: legacyLocation.path) {
                Log.warn("""
                    \(url.path) holds nothing but defaults while \(legacyLocation.path) still \
                    exists. The paired pen is in the older file and was not adopted. Move it \
                    across with: rm \(url.path) && mv \(legacyLocation.deletingLastPathComponent().path)/* \
                    \(url.deletingLastPathComponent().path)/
                    """)
            }
            return config
        }
        let config = Config()
        try config.save(to: url)
        return config
    }

    public func save(to url: URL = defaultLocation) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// One pen this Mac accepts.
public struct PairedPen: Codable, Equatable {
    /// Bluetooth MAC, lowercase and unpunctuated, as `PenRecord.mac`. Empty when only the
    /// peripheral identifier is known.
    public var mac: String
    /// CoreBluetooth identifier, for reconnects where the MAC is not advertised.
    public var peripheralId: String?

    public init(mac: String, peripheralId: String? = nil) {
        self.mac = PenRecord.normalise(mac)
        self.peripheralId = peripheralId
    }

    /// A MAC typed in by hand, colons and capitals included, still matches the pen.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mac: try c.decodeIfPresent(String.self, forKey: .mac) ?? "",
                  peripheralId: try c.decodeIfPresent(String.self, forKey: .peripheralId))
    }
}
