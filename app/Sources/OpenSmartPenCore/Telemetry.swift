import Foundation

/// A value on an event. Four kinds, which is what a collector can index.
public enum TelemetryValue: Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

extension TelemetryValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

public enum TelemetryLevel: String {
    case info, warn, error, fatal
}

/// One thing that happened: a click, a pen that connected, a problem.
public struct TelemetryEvent: Equatable {
    /// `pen.connected`, `ui.panel.opened`. Nil for a line from the log, which has only words.
    public var name: String?
    public var level: TelemetryLevel
    public var attributes: [String: TelemetryValue]
    /// The words, for a line from the log or a crash.
    public var body: String?
    /// When it happened. A crash is reported at the next start, with the time of the crash.
    public var time: Date

    public init(name: String?, level: TelemetryLevel = .info, attributes: [String: TelemetryValue] = [:],
                body: String? = nil, time: Date = Date()) {
        self.name = name
        self.level = level
        self.attributes = attributes
        self.body = body
        self.time = time
    }
}

/// Work that takes time: an upload, a drain of pen memory. It has a start, an end and a result.
public protocol TelemetrySpan: AnyObject {
    func set(_ key: String, _ value: TelemetryValue)
    /// `error` is nil when the work went well.
    func end(error: String?)
}

extension TelemetrySpan {
    public func end() { end(error: nil) }
}

/// Where events go. In the app that is the OpenTelemetry SDK; in a test, a list.
public protocol TelemetrySink: AnyObject {
    func record(_ event: TelemetryEvent)
    func begin(_ name: String, attributes: [String: TelemetryValue], parent: TelemetrySpan?) -> TelemetrySpan
}

/// What the app tells its makers about how it is used and what goes wrong.
///
/// A global, like `Log`, and for the same reason: every layer has something to say, and handing
/// an object to each of them would put telemetry in every initialiser. The domain and the UI
/// call this and know nothing of OpenTelemetry; the app target gives it a sink.
///
/// It has three states. Off: every call does nothing. Holding: events are kept in memory and
/// nothing leaves the Mac, which is the state from the start of the app until the person has
/// been told about telemetry. On: events go to the sink.
///
/// Never put in an event: what was written, a notebook's title, a name a person gave a pen, a
/// file name, a bucket or its keys. `docs/telemetry.md` is the list of what is sent.
public enum Telemetry {
    private enum State {
        case off
        case holding([TelemetryEvent])
        case on(TelemetrySink)
    }

    private static let lock = NSLock()
    private static var state: State = .off
    private static var cleaner = TelemetryScrubber()
    /// The most events kept while holding. The first hour of a first start fits many times over.
    static let holdLimit = 500

    /// Keep events in memory until `start` or `stop`.
    public static func hold() {
        lock.lock(); defer { lock.unlock() }
        if case .off = state { state = .holding([]) }
    }

    /// Send events to this sink, the held ones first.
    public static func start(_ sink: TelemetrySink) {
        lock.lock()
        var held: [TelemetryEvent] = []
        if case let .holding(events) = state { held = events }
        state = .on(sink)
        lock.unlock()
        for event in held { sink.record(event) }
    }

    /// Stop, and drop what was held. Nothing held is sent later.
    public static func stop() {
        lock.lock(); defer { lock.unlock() }
        state = .off
    }

    public static var isOn: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .on = state { return true }
        return false
    }

    /// The text that must not leave the Mac, and what stands in its place.
    public static var scrubber: TelemetryScrubber {
        get { lock.lock(); defer { lock.unlock() }; return cleaner }
        set { lock.lock(); cleaner = newValue; lock.unlock() }
    }

    // MARK: events

    public static func event(_ name: String, _ attributes: [String: TelemetryValue] = [:],
                             level: TelemetryLevel = .info, body: String? = nil, time: Date = Date()) {
        record(TelemetryEvent(name: name, level: level, attributes: attributes, body: body, time: time))
    }

    /// A warning or an error from the log. `Log` calls this; nothing else needs to.
    static func problem(_ level: TelemetryLevel, _ message: String) {
        record(TelemetryEvent(name: nil, level: level, body: message))
    }

    private static func record(_ event: TelemetryEvent) {
        lock.lock()
        let scrub = cleaner
        switch state {
        case .off:
            lock.unlock()
        case var .holding(events):
            if events.count < holdLimit { events.append(scrub.clean(event)) }
            state = .holding(events)
            lock.unlock()
        case let .on(sink):
            lock.unlock()
            sink.record(scrub.clean(event))
        }
    }

    // MARK: spans

    /// Start work that ends later, on any thread: a pen connecting, a notebook leaving pen memory.
    public static func begin(_ name: String, _ attributes: [String: TelemetryValue] = [:]) -> TelemetrySpan {
        lock.lock()
        let scrub = cleaner
        guard case let .on(sink) = state else {
            lock.unlock()
            return SilentSpan()
        }
        lock.unlock()
        // The sink is given its own span as the parent, not the wrapper around it.
        let parent = (stack.last as? ScrubbedSpan)?.inner
        return ScrubbedSpan(sink.begin(name, attributes: scrub.clean(attributes), parent: parent), scrub)
    }

    /// Time work that is done on this thread. Work timed inside it becomes a part of it, and a
    /// thrown error ends it as failed.
    public static func span<T>(_ name: String, _ attributes: [String: TelemetryValue] = [:],
                               _ work: (TelemetrySpan) throws -> T) rethrows -> T {
        let span = begin(name, attributes)
        stack.append(span)
        defer { stack.removeLast() }
        do {
            let result = try work(span)
            span.end(error: nil)
            return result
        } catch {
            span.end(error: describe(error))
            throw error
        }
    }

    /// An error in words. The localised sentence when there is one, which is what a person saw.
    public static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// The spans open on this thread, innermost last.
    private static var stack: [TelemetrySpan] {
        get { Thread.current.threadDictionary[stackKey] as? [TelemetrySpan] ?? [] }
        set { Thread.current.threadDictionary[stackKey] = newValue }
    }

    private static let stackKey = "org.opensmartpen.telemetry.spans"
}

/// A span while telemetry is off or holding. It does nothing.
private final class SilentSpan: TelemetrySpan {
    func set(_ key: String, _ value: TelemetryValue) {}
    func end(error: String?) {}
}

/// Cleans what is put on a span after it has started.
private final class ScrubbedSpan: TelemetrySpan {
    let inner: TelemetrySpan
    private let scrubber: TelemetryScrubber

    init(_ inner: TelemetrySpan, _ scrubber: TelemetryScrubber) {
        self.inner = inner
        self.scrubber = scrubber
    }

    func set(_ key: String, _ value: TelemetryValue) { inner.set(key, scrubber.clean(value)) }
    func end(error: String?) { inner.end(error: error.map(scrubber.clean)) }
}

/// Takes private text out of everything that leaves: every string on every event and span.
///
/// Most events carry no free text. The ones that do are log lines and error messages, and an
/// error from the file system or from a bucket can name a path or a bucket. This is the net
/// under them. It is not a reason to put a name in an event.
public struct TelemetryScrubber: Equatable {
    /// The home folder, which has the person's account name in it.
    public var home: String
    /// Private text and what replaces it: the bucket, the folder in it, the key id.
    public private(set) var terms: [Term] = []

    public struct Term: Equatable {
        public let text: String
        public let placeholder: String
    }

    /// No string leaves longer than this. A stack trace is the longest thing sent.
    public static let limit = 8000

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.home = home
    }

    /// Replace `text` with `<name>` wherever it shows. Text of one or two letters is left
    /// alone: replacing every "a" would destroy the message and hide nothing.
    public mutating func hide(_ text: String, as name: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3, !terms.contains(where: { $0.text == text }) else { return }
        terms.append(Term(text: text, placeholder: "<\(name)>"))
        // The longest first, so a bucket whose name contains the folder's is replaced whole.
        terms.sort { $0.text.count > $1.text.count }
    }

    public func clean(_ text: String) -> String {
        var out = text
        // Every term in one pass, and whole words only. One pass, so a placeholder is never
        // read as private text itself; whole words, so a folder in the bucket called "pen"
        // does not turn every "pens" and "open" in a message into a placeholder.
        if !terms.isEmpty {
            let words = terms.map { NSRegularExpression.escapedPattern(for: $0.text) }.joined(separator: "|")
            if let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])(?:" + words + ")(?![A-Za-z0-9])") {
                let found = regex.matches(in: out, range: NSRange(out.startIndex..., in: out))
                for match in found.reversed() {
                    guard let range = Range(match.range, in: out),
                          let term = terms.first(where: { $0.text == out[range] }) else { continue }
                    out.replaceSubrange(range, with: term.placeholder)
                }
            }
        }
        // A pen's file is named after the name a person gave the pen.
        out = out.replacingOccurrences(of: #"pens/[^/\s"']+\.json"#, with: "pens/<pen>.json",
                                       options: .regularExpression)
        if home.count > 1 { out = out.replacingOccurrences(of: home, with: "~") }
        return out.count > Self.limit ? String(out.prefix(Self.limit)) + "…" : out
    }

    func clean(_ value: TelemetryValue) -> TelemetryValue {
        if case let .string(text) = value { return .string(clean(text)) }
        return value
    }

    func clean(_ attributes: [String: TelemetryValue]) -> [String: TelemetryValue] {
        attributes.mapValues(clean)
    }

    func clean(_ event: TelemetryEvent) -> TelemetryEvent {
        var event = event
        event.attributes = clean(event.attributes)
        event.body = event.body.map(clean)
        return event
    }
}

/// Keeps what it is given. For tests.
public final class RecordingTelemetry: TelemetrySink {
    public struct Span: Equatable {
        public var name: String
        public var attributes: [String: TelemetryValue]
        public var parent: String?
        public var ended = false
        public var error: String?
    }

    private let lock = NSLock()
    private var kept: [TelemetryEvent] = []
    private var open: [Recorded] = []

    public init() {}

    public var events: [TelemetryEvent] {
        lock.lock(); defer { lock.unlock() }
        return kept
    }

    public var spans: [Span] {
        lock.lock(); defer { lock.unlock() }
        return open.map(\.span)
    }

    /// The names of the events, in order, without the lines from the log.
    public var names: [String] { events.compactMap(\.name) }

    public func record(_ event: TelemetryEvent) {
        lock.lock(); defer { lock.unlock() }
        kept.append(event)
    }

    public func begin(_ name: String, attributes: [String: TelemetryValue], parent: TelemetrySpan?) -> TelemetrySpan {
        lock.lock(); defer { lock.unlock() }
        let parentName = open.first { $0 === parent }?.span.name
        let span = Recorded(Span(name: name, attributes: attributes, parent: parentName), lock)
        open.append(span)
        return span
    }

    private final class Recorded: TelemetrySpan {
        var span: Span
        private let lock: NSLock

        init(_ span: Span, _ lock: NSLock) {
            self.span = span
            self.lock = lock
        }

        func set(_ key: String, _ value: TelemetryValue) {
            lock.lock(); defer { lock.unlock() }
            span.attributes[key] = value
        }

        func end(error: String?) {
            lock.lock(); defer { lock.unlock() }
            span.ended = true
            span.error = error
        }
    }
}
