import Foundation

/// User configuration, stored as JSON at ~/.config/opensmartpen/config.json.
/// Every field has a default so the app runs with no setup; the file is written on first launch.
public struct Config: Codable, Equatable {
    /// Where everything the pen captures is kept, and the readable files made from it.
    ///
    /// Outside the app on purpose, so the app can be deleted and installed again without taking
    /// the notes with it (ADR-002).
    public var dataPath: String = "~/OpenSmartPen"
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
    /// Start the app when this person logs in. On unless they turn it off: a pen that is written
    /// with while the app is not running keeps its pages to itself until somebody remembers.
    public var startAtLogin: Bool = true
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
        startAtLogin = try c.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? d.startAtLogin
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

    /// `penMac` and `penPeripheralId` are decoded but never encoded, so an old config does not
    /// carry the old shape forward once it has been read. Keys the app no longer has are not read
    /// at all, and fall out of the file the next time it is saved.
    private enum CodingKeys: String, CodingKey {
        case dataPath, quietSeconds, pairedPens, penMac, penPeripheralId, penPassword
        case deleteFromPenAfterPublish, s3, penAutoPowerOn, penAutoPowerOffMinutes
        case penCapPowerOff, controlBooks, lowBatteryPercent, memoryWarnPercent, sdkDebugLog
        case startAtLogin
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dataPath, forKey: .dataPath)
        try c.encode(quietSeconds, forKey: .quietSeconds)
        try c.encode(pairedPens, forKey: .pairedPens)
        try c.encodeIfPresent(penPassword, forKey: .penPassword)
        try c.encode(deleteFromPenAfterPublish, forKey: .deleteFromPenAfterPublish)
        try c.encode(startAtLogin, forKey: .startAtLogin)
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
        configBase.appendingPathComponent("opensmartpen/config.json")
    }

    /// Load the config, creating the file with defaults when it does not exist.
    public static func loadOrCreate(at url: URL = defaultLocation) throws -> Config {
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
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
