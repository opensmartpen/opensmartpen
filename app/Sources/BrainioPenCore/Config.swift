import Foundation

/// User configuration, stored as JSON at ~/.config/brainio-pen/config.json.
/// Every field has a default so the app runs with no setup; the file is written on first launch.
public struct Config: Codable, Equatable {
    /// Git repository that receives the raw stroke files.
    public var repoPath: String = "~/BrainioPen/notes"
    /// Minutes without strokes before a page is published.
    public var quietMinutes: Double = 10
    /// Bluetooth MAC of the paired pen. Nil until the first pen is paired automatically.
    public var penMac: String?
    /// CoreBluetooth identifier of the paired pen, for reconnects where the MAC is not advertised.
    public var penPeripheralId: String?
    /// PIN for a password-protected pen. Nil means no PIN.
    public var penPassword: String?
    /// Delete a notebook from pen memory once its strokes are committed and pushed.
    public var deleteFromPenAfterPublish: Bool = true
    /// Push after every commit. Turn off to work fully offline.
    public var gitPush: Bool = true
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

    /// Missing keys take their defaults, so an older or hand-edited file keeps loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        repoPath = try c.decodeIfPresent(String.self, forKey: .repoPath) ?? d.repoPath
        quietMinutes = try c.decodeIfPresent(Double.self, forKey: .quietMinutes) ?? d.quietMinutes
        penMac = try c.decodeIfPresent(String.self, forKey: .penMac)
        penPeripheralId = try c.decodeIfPresent(String.self, forKey: .penPeripheralId)
        penPassword = try c.decodeIfPresent(String.self, forKey: .penPassword)
        deleteFromPenAfterPublish = try c.decodeIfPresent(Bool.self, forKey: .deleteFromPenAfterPublish) ?? d.deleteFromPenAfterPublish
        penAutoPowerOn = try c.decodeIfPresent(Bool.self, forKey: .penAutoPowerOn)
        penAutoPowerOffMinutes = try c.decodeIfPresent(Int.self, forKey: .penAutoPowerOffMinutes)
        penCapPowerOff = try c.decodeIfPresent(Bool.self, forKey: .penCapPowerOff)
        controlBooks = try c.decodeIfPresent([String].self, forKey: .controlBooks) ?? d.controlBooks
        gitPush = try c.decodeIfPresent(Bool.self, forKey: .gitPush) ?? d.gitPush
        lowBatteryPercent = try c.decodeIfPresent(Int.self, forKey: .lowBatteryPercent) ?? d.lowBatteryPercent
        memoryWarnPercent = try c.decodeIfPresent(Int.self, forKey: .memoryWarnPercent) ?? d.memoryWarnPercent
        sdkDebugLog = try c.decodeIfPresent(Bool.self, forKey: .sdkDebugLog) ?? d.sdkDebugLog
    }

    public var repoURL: URL {
        URL(fileURLWithPath: (repoPath as NSString).expandingTildeInPath)
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
    /// The whole directory is taken, not just `config.json`: `pen-state.json` sits beside it and a
    /// half-migrated directory would forget which pen was flat. It is *copied* rather than moved —
    /// an install that is still running on the old name keeps working, and nothing is destroyed by
    /// a first launch. Does nothing once the new directory exists, so it runs at most once.
    @discardableResult
    static func adoptLegacyDirectory(at url: URL = defaultLocation,
                                     legacy: URL = legacyLocation) -> Bool {
        let fm = FileManager.default
        let new = url.deletingLastPathComponent()
        let old = legacy.deletingLastPathComponent()
        guard !fm.fileExists(atPath: new.path),
              fm.fileExists(atPath: legacy.path) else { return false }
        do {
            try fm.copyItem(at: old, to: new)
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
        if url == defaultLocation, !fm.fileExists(atPath: url.path) { adoptLegacyDirectory(at: url) }
        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(Config.self, from: data)
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
