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

/// A number the app keeps: how many, how long, how much there is right now.
///
/// A metric is added up before it leaves, so it says nothing about one moment or one page. Its
/// attributes are a few fixed words (`live`, `quiet`, `strokes`), never an address of a pen and
/// never anything a person named: each different value is one more series kept for ever.
public struct TelemetryMetric: Hashable {
    public enum Kind: String {
        /// Only goes up: strokes written, files uploaded.
        case counter
        /// How a value is spread: how long an upload takes.
        case histogram
        /// What it is now: how many pages wait.
        case gauge
    }

    public let name: String
    public let kind: Kind
    /// As OpenTelemetry asks: `s`, `By`, or a thing in braces, `{page}`.
    public let unit: String
    public let description: String

    init(_ name: String, _ kind: Kind, unit: String, _ description: String) {
        self.name = name
        self.kind = kind
        self.unit = unit
        self.description = description
    }
}

extension TelemetryMetric {
    /// How long each piece of timed work took. One histogram for every span, so a new span is
    /// measured from the day it is written. `operation` is the name of the span.
    public static let operationDuration = TelemetryMetric(
        "opensmartpen.operation.duration", .histogram, unit: "s",
        "How long a piece of work took, by its name and whether it went well")
    public static let strokes = TelemetryMetric(
        "opensmartpen.strokes", .counter, unit: "{stroke}",
        "Strokes that arrived from a pen, live or from pen memory")
    public static let pagesPublished = TelemetryMetric(
        "opensmartpen.pages.published", .counter, unit: "{page}",
        "Pages in an upload that went well, by why the upload began")
    public static let filesUploaded = TelemetryMetric(
        "opensmartpen.upload.files", .counter, unit: "{file}",
        "Files put in the bucket, by kind of file")
    public static let bytesUploaded = TelemetryMetric(
        "opensmartpen.upload.bytes", .counter, unit: "By",
        "Bytes put in the bucket, by kind of file")
    public static let photos = TelemetryMetric(
        "opensmartpen.photos", .counter, unit: "{photo}",
        "Photos filed as pages, by where they came from")
    public static let problems = TelemetryMetric(
        "opensmartpen.log.problems", .counter, unit: "{line}",
        "Lines written to the log as a warning or an error, by level")
    public static let pagesPending = TelemetryMetric(
        "opensmartpen.pages.pending", .gauge, unit: "{page}",
        "Pages written and not yet uploaded")
    public static let uploadFailures = TelemetryMetric(
        "opensmartpen.sync.consecutive_failures", .gauge, unit: "{upload}",
        "Uploads that failed in a row; 0 when the last one went well")
    public static let pensPaired = TelemetryMetric(
        "opensmartpen.pens.paired", .gauge, unit: "{pen}", "Pens this Mac accepts")
    public static let pensConnected = TelemetryMetric(
        "opensmartpen.pens.connected", .gauge, unit: "{pen}", "Pens connected now")
    public static let books = TelemetryMetric(
        "opensmartpen.books", .gauge, unit: "{book}", "Notebooks this Mac knows")
    public static let agents = TelemetryMetric(
        "opensmartpen.agents", .gauge, unit: "{agent}", "Agents that read the bucket")
    public static let memory = TelemetryMetric(
        "process.memory.usage", .gauge, unit: "By", "Memory the app holds")
    public static let uptime = TelemetryMetric(
        "process.uptime", .gauge, unit: "s", "How long the app has run")

    /// Every metric the app keeps. `docs/telemetry.md` lists each of them, and a test checks it.
    public static let all: [TelemetryMetric] = [
        operationDuration, strokes, pagesPublished, filesUploaded, bytesUploaded, photos, problems,
        pagesPending, uploadFailures, pensPaired, pensConnected, books, agents, memory, uptime,
    ]

    /// The steps of a histogram of seconds: from a file that goes up in a blink to a notebook
    /// that takes minutes to leave pen memory.
    public static let secondsBuckets: [Double] = [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300, 600]
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
    /// `span` is the work the event happened in, if it happened in any: the sink's own span.
    func record(_ event: TelemetryEvent, in span: TelemetrySpan?)
    func begin(_ name: String, attributes: [String: TelemetryValue], parent: TelemetrySpan?) -> TelemetrySpan
    /// Add to a counter, put a value in a histogram, or say what a gauge is now.
    func measure(_ metric: TelemetryMetric, _ value: Double, attributes: [String: TelemetryValue])
}

/// What the app tells its makers about how it is used and what goes wrong.
///
/// A global, like `Log`, and for the same reason: every layer has something to say, and handing
/// an object to each of them would put telemetry in every initialiser. The domain and the UI
/// call this and know nothing of OpenTelemetry; the app target gives it a sink.
///
/// It has three states. Off: every call does nothing. Holding: events are kept in memory and
/// no event leaves the Mac, which is the state from the start of the app until the person has
/// been told about telemetry. On: events go to the sink.
///
/// Never put in an event: what was written, a notebook's title, a name a person gave a pen, a
/// file name, a bucket or its keys. `docs/telemetry.md` is the list of what is sent.
public enum Telemetry {
    private enum State {
        case off
        case holding(Held)
        case on(TelemetrySink)
    }

    /// What waits while the person has not been told.
    private struct Held {
        var events: [TelemetryEvent] = []
        /// A counter and a gauge wait as one number for each set of attributes: a counter adds
        /// up and a gauge keeps the last. So an hour of writing does not push the events out.
        var numbers: [Series: Double] = [:]
        /// A histogram needs each value.
        var samples: [(series: Series, value: Double)] = []
    }

    private struct Series: Hashable {
        let metric: TelemetryMetric
        let attributes: [String: TelemetryValue]
    }

    private static let lock = NSLock()
    private static var state: State = .off
    private static var cleaner = TelemetryScrubber()
    /// The most events and numbers kept while holding. The first hour of a first start fits
    /// many times over.
    static let holdLimit = 500

    /// Keep events in memory until `start` or `stop`.
    public static func hold() {
        lock.lock(); defer { lock.unlock() }
        if case .off = state { state = .holding(Held()) }
    }

    /// Send events to this sink, the held ones first.
    public static func start(_ sink: TelemetrySink) {
        lock.lock()
        var held = Held()
        if case let .holding(kept) = state { held = kept }
        state = .on(sink)
        lock.unlock()
        for event in held.events { sink.record(event, in: nil) }
        for (series, value) in held.numbers { sink.measure(series.metric, value, attributes: series.attributes) }
        for sample in held.samples { sink.measure(sample.series.metric, sample.value, attributes: sample.series.attributes) }
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
    ///
    /// `file` is the place in the source that wrote the line, as `Module/File.swift`: the same
    /// for everybody, so it is not a path on anybody's Mac.
    static func problem(_ level: TelemetryLevel, _ message: String, file: String = "", line: Int = 0) {
        var attributes: [String: TelemetryValue] = [:]
        if !file.isEmpty {
            attributes["code.file.path"] = .string(file)
            attributes["code.line.number"] = .int(line)
        }
        record(TelemetryEvent(name: nil, level: level, attributes: attributes, body: message))
        count(.problems, ["log.level": .string(level.rawValue)])
    }

    private static func record(_ event: TelemetryEvent) {
        lock.lock()
        let scrub = cleaner
        switch state {
        case .off:
            lock.unlock()
        case var .holding(held):
            if held.events.count < holdLimit { held.events.append(scrub.clean(event)) }
            state = .holding(held)
            lock.unlock()
        case let .on(sink):
            lock.unlock()
            // The work this thread is in the middle of. The sink ties the event to it, so a
            // line of the log can be read beside the upload that wrote it.
            sink.record(scrub.clean(event), in: (stack.last as? ScrubbedSpan)?.inner)
        }
    }

    // MARK: metrics

    /// Add to a counter.
    public static func count(_ metric: TelemetryMetric, _ attributes: [String: TelemetryValue] = [:], by amount: Int = 1) {
        guard amount > 0 else { return }
        measure(metric, Double(amount), attributes)
    }

    /// Put a value in a histogram, or say what a gauge is now.
    public static func measure(_ metric: TelemetryMetric, _ value: Double, _ attributes: [String: TelemetryValue] = [:]) {
        lock.lock()
        let scrub = cleaner
        switch state {
        case .off:
            lock.unlock()
        case var .holding(held):
            let series = Series(metric: metric, attributes: scrub.clean(attributes))
            switch metric.kind {
            case .counter: held.numbers[series, default: 0] += value
            case .gauge: held.numbers[series] = value
            case .histogram: if held.samples.count < holdLimit { held.samples.append((series, value)) }
            }
            state = .holding(held)
            lock.unlock()
        case let .on(sink):
            lock.unlock()
            sink.measure(metric, value, attributes: scrub.clean(attributes))
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
        return ScrubbedSpan(sink.begin(name, attributes: scrub.clean(attributes), parent: parent), scrub, name: name)
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

/// Cleans what is put on a span after it has started, and measures how long the work took.
private final class ScrubbedSpan: TelemetrySpan {
    let inner: TelemetrySpan
    private let scrubber: TelemetryScrubber
    private let name: String
    private let started = Date()
    private let lock = NSLock()
    private var ended = false

    init(_ inner: TelemetrySpan, _ scrubber: TelemetryScrubber, name: String) {
        self.inner = inner
        self.scrubber = scrubber
        self.name = name
    }

    func set(_ key: String, _ value: TelemetryValue) { inner.set(key, scrubber.clean(value)) }

    func end(error: String?) {
        lock.lock()
        let first = !ended
        ended = true
        lock.unlock()
        // Ended once. A pen that drops while its notebook is leaving ends the same work twice.
        guard first else { return }
        inner.end(error: error.map(scrubber.clean))
        Telemetry.measure(.operationDuration, Date().timeIntervalSince(started),
                          ["operation": .string(name), "outcome": error == nil ? "ok" : "error"])
    }
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

    public struct Measurement: Equatable {
        public var metric: TelemetryMetric
        public var value: Double
        public var attributes: [String: TelemetryValue]
    }

    private let lock = NSLock()
    private var kept: [TelemetryEvent] = []
    private var within: [String?] = []
    private var numbers: [Measurement] = []
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

    /// For each event, the name of the span it happened in, or nil.
    public var eventSpans: [String?] {
        lock.lock(); defer { lock.unlock() }
        return within
    }

    public var measurements: [Measurement] {
        lock.lock(); defer { lock.unlock() }
        return numbers
    }

    /// The sum of what was given to a metric, for the measurements with these attributes.
    public func total(_ metric: TelemetryMetric, where attributes: [String: TelemetryValue] = [:]) -> Double {
        measurements.filter { m in m.metric == metric && attributes.allSatisfy { m.attributes[$0.key] == $0.value } }
            .map(\.value).reduce(0, +)
    }

    public func record(_ event: TelemetryEvent, in span: TelemetrySpan?) {
        lock.lock(); defer { lock.unlock() }
        kept.append(event)
        within.append(open.first { $0 === span }?.span.name)
    }

    public func measure(_ metric: TelemetryMetric, _ value: Double, attributes: [String: TelemetryValue]) {
        lock.lock(); defer { lock.unlock() }
        numbers.append(Measurement(metric: metric, value: value, attributes: attributes))
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
