import Foundation

/// Something the person should see. Everything else goes to the log.
public struct Notice {
    /// Stable key used to suppress repeats of the same problem.
    public let key: String
    public let title: String
    public let body: String
    public init(key: String, title: String, body: String) {
        self.key = key
        self.title = title
        self.body = body
    }

    /// The key without the pen it is about: `battery` for `battery-9c7bd2000001`. A notice about
    /// one pen ends in that pen's address, or in the identifier Bluetooth gave it.
    public var kind: String {
        key.replacingOccurrences(of: Self.penSuffix, with: "", options: .regularExpression)
    }

    /// The address of the pen the notice is about, when the key ends in one.
    public var penMac: String? {
        guard let range = key.range(of: "-[0-9a-f]{12}$", options: .regularExpression) else { return nil }
        return String(key[range].dropFirst())
    }

    private static let penSuffix = "-([0-9a-f]{12}|[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})$"
    /// Notices that are news, not problems.
    static let goodNews: Set<String> = ["paired", "new-pen", "publish-recovered"]
}

public protocol Notifier: AnyObject {
    func post(_ notice: Notice)
}

/// Suppresses repeats of the same notice key within a window, so a flapping condition
/// does not produce a stream of notifications.
public final class DedupingNotifier: Notifier {
    private let inner: Notifier
    private let window: TimeInterval
    private var lastSent: [String: Date] = [:]
    private let now: () -> Date

    public init(_ inner: Notifier, window: TimeInterval = 30 * 60, now: @escaping () -> Date = Date.init) {
        self.inner = inner
        self.window = window
        self.now = now
    }

    public func post(_ notice: Notice) {
        let t = now()
        if let last = lastSent[notice.key], t.timeIntervalSince(last) < window { return }
        lastSent[notice.key] = t
        // Every notice also goes to the log, so a run without notification permission is still diagnosable.
        // The words stay on this Mac: they name the pen as the person named it. Telemetry gets
        // which notice it was, and for which pen.
        Log.warn("notice[\(notice.key)] \(notice.title): \(notice.body)", telemetry: false)
        var attributes: [String: TelemetryValue] = ["notice.key": .string(notice.kind)]
        if let mac = notice.penMac { attributes["pen.mac"] = .string(mac) }
        Telemetry.event("notice.posted", attributes,
                        level: Notice.goodNews.contains(notice.kind) ? .info : .warn)
        inner.post(notice)
    }

    /// Forget a key so the next occurrence notifies again (call when the condition clears).
    public func reset(_ key: String) { lastSent.removeValue(forKey: key) }
}

/// Fallback when the process has no bundle (plain `swift run`): uses AppleScript.
public final class OSAScriptNotifier: Notifier {
    public init() {}
    public func post(_ notice: Notice) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "display notification \"\(esc(notice.body))\" with title \"\(esc(notice.title))\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}

/// Collects notices; used by tests and by the menu's recent-events list.
public final class RecordingNotifier: Notifier {
    public private(set) var notices: [Notice] = []
    public init() {}
    public func post(_ notice: Notice) { notices.append(notice) }
}
