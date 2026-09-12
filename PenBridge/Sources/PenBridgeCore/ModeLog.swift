import Foundation

public enum ModeSource: String, Codable {
    /// A tap on the paper controller.
    case paper
    /// A click in the PenBridge panel.
    case panel
}

/// One change of ink colour or line width, at the moment it was made.
///
/// Only the field that changed is recorded. Writing the full state instead would be simpler to
/// read, but it cannot survive the way taps actually arrive: a tap made away from the Mac sits
/// in pen memory and is delivered at the next drain, hours later and after events that happened
/// long afterwards. A line claiming the full state at 09:14 would be describing the state at
/// 18:10, when it was written. A change on its own is true whenever it is written down.
public struct ModeEvent: Equatable {
    /// Epoch milliseconds, on the same clock as a stroke's `start`. This is the tap's own time,
    /// not the time it reached us.
    public var at: Int
    public var ink: InkColor?
    public var width: LineWidth?
    public var source: ModeSource
    /// The control tap this came from, so the event can be traced back to its evidence in raw.
    public var tap: UUID?

    public init(at: Int, ink: InkColor? = nil, width: LineWidth? = nil,
                source: ModeSource, tap: UUID? = nil) {
        self.at = at
        self.ink = ink
        self.width = width
        self.source = source
        self.tap = tap
    }

    var jsonLine: String {
        var out = "{\"t\":\"mode\",\"at\":\(at)"
        if let ink { out += ",\"ink\":\"\(ink.rawValue)\"" }
        if let width { out += ",\"width\":\"\(width.rawValue)\"" }
        out += ",\"src\":\"\(source.rawValue)\""
        if let tap { out += ",\"tap\":\"\(tap.uuidString.lowercased())\"" }
        return out + "}"
    }

    init?(json o: [String: Any]) {
        guard o["t"] as? String == "mode", let at = (o["at"] as? NSNumber)?.intValue else { return nil }
        self.at = at
        ink = (o["ink"] as? String).flatMap(InkColor.init(rawValue:))
        width = (o["width"] as? String).flatMap(LineWidth.init(rawValue:))
        source = (o["src"] as? String).flatMap(ModeSource.init(rawValue:)) ?? .paper
        tap = (o["tap"] as? String).flatMap(UUID.init(uuidString:))
        if ink == nil && width == nil { return nil }
    }
}

/// The ink colour and line width chosen over time, appended to `raw/mode.jsonl`.
///
/// Only deliberate human acts are written here: a tap on the paper controller and a click in the
/// panel. Returning to the pen's defaults after a long gap is NOT an event — it is derived from
/// the gap between consecutive strokes, which every stroke already carries in its own timestamp.
/// Nothing has to be written down for it, so nothing can fall out of step.
///
/// Append-only and never rewritten. Both writers — the paper controller and the panel — are in
/// this one process, so there is no locking to do. Rendering joins a stroke to the state by
/// replaying every event at or before the stroke's own start time.
public final class ModeLog {
    public static let relativePath = "raw/mode.jsonl"

    private let url: URL
    private let fm = FileManager.default
    private(set) var events: [ModeEvent] = []
    /// Fired after a change is recorded, with the state that is now in force. The pen's LED
    /// follows this: it cannot be told the ink colour, but it can acknowledge the choice.
    public var onChange: ((InkColor, LineWidth) -> Void)?

    public init(root: URL) {
        url = root.appendingPathComponent(Self.relativePath)
        events = Self.read(url)
    }

    /// The state in force at a moment, replayed from every earlier event. Events are replayed in
    /// time order rather than file order, because an offline drain appends them out of order.
    public func state(at ms: Int) -> (ink: InkColor, width: LineWidth) {
        var ink = InkColor.black
        var width = LineWidth.default
        for e in events.sorted(by: { $0.at < $1.at }) where e.at <= ms {
            if let i = e.ink { ink = i }
            if let w = e.width { width = w }
        }
        return (ink, width)
    }

    /// What is selected now, for the panel.
    public var current: (ink: InkColor, width: LineWidth) {
        state(at: Int(Date().timeIntervalSince1970 * 1000))
    }

    /// Record a change. Returns false when nothing actually changed, so a re-tap of the button
    /// that is already selected costs nothing — it is still logged as evidence that the pen woke,
    /// but it is not written twice.
    @discardableResult
    public func record(_ button: ControlButton, at ms: Int, source: ModeSource, tap: UUID? = nil) -> Bool {
        let now = state(at: ms)
        let event: ModeEvent
        switch button {
        case let .ink(c):
            // White is deliberately inert: Matous has not decided whether that swatch means white
            // ink, an eraser, or nothing, so tapping it changes nothing. The tap is still stored in
            // raw and logged. A dead button is easier to explain than a live one that silently
            // renders a page in an ink we never measured.
            guard c != .white else { return false }
            guard c != now.ink else { return false }
            event = ModeEvent(at: ms, ink: c, source: source, tap: tap)
        case let .width(w):
            guard w != now.width else { return false }
            event = ModeEvent(at: ms, width: w, source: source, tap: tap)
        }
        append(event)
        let after = state(at: ms)
        onChange?(after.ink, after.width)
        return true
    }

    func append(_ event: ModeEvent) {
        events.append(event)
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let line = Data((event.jsonLine + "\n").utf8)
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            Log.error("writing \(Self.relativePath) failed: \(error)")
        }
    }

    static func read(_ url: URL) -> [ModeEvent] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return ModeEvent(json: o)
        }
    }
}
