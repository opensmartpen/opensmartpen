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
