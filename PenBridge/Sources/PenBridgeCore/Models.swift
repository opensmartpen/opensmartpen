import Foundation

/// Ncode page identity as reported by the pen. Owner 27 is NeoLAB's own notebooks.
public struct PageID: Hashable, Codable, CustomStringConvertible {
    public let section: Int
    public let owner: Int
    public let book: Int
    public let page: Int

    public init(section: Int, owner: Int, book: Int, page: Int) {
        self.section = section
        self.owner = owner
        self.book = book
        self.page = page
    }

    /// Repo-relative path of this page's raw JSONL file. See docs/stroke-format.md.
    public var rawRelativePath: String {
        "raw/s\(section)/o\(owner)/b\(book)/p\(page).jsonl"
    }

    public var description: String { "s\(section)/o\(owner)/b\(book)/p\(page)" }
}

/// One sample from the pen, in Ncode cells.
public struct DotSample: Equatable {
    public var x: Double
    public var y: Double
    /// 0…1
    public var force: Double
    /// Milliseconds since the previous dot of the stroke; 0 for the first.
    public var dt: Int
    public var tiltX: Int?
    public var tiltY: Int?
    public var twist: Int?

    public init(x: Double, y: Double, force: Double, dt: Int, tiltX: Int? = nil, tiltY: Int? = nil, twist: Int? = nil) {
        self.x = x
        self.y = y
        self.force = force
        self.dt = dt
        self.tiltX = tiltX
        self.tiltY = tiltY
        self.twist = twist
    }
}

public enum StrokeSource: String {
    case live
    case offline
}

public enum TipType: String {
    case pen
    case eraser
}

/// Pen-down to pen-up on one page.
public struct Stroke: Equatable {
    public var id: UUID
    public var page: PageID
    /// Epoch milliseconds of the first dot.
    public var start: Int
    /// Epoch milliseconds of the last dot.
    public var end: Int
    public var tip: TipType
    /// CSS hex colour, e.g. "#000000".
    public var color: String
    public var dots: [DotSample]
    public var source: StrokeSource
    public var penMac: String
    public var firmware: String

    public init(id: UUID = UUID(), page: PageID, start: Int, end: Int, tip: TipType = .pen, color: String = "#000000",
                dots: [DotSample], source: StrokeSource, penMac: String, firmware: String) {
        self.id = id
        self.page = page
        self.start = start
        self.end = end
        self.tip = tip
        self.color = color
        self.dots = dots
        self.source = source
        self.penMac = penMac
        self.firmware = firmware
    }
}

/// Serialises records to the JSON Lines shape in docs/stroke-format.md.
/// Hand-rolled so that number formatting is stable and diffs stay small.
public enum JSONL {
    public static func strokeLine(_ s: Stroke) -> String {
        var out = "{\"t\":\"stroke\""
        out += ",\"id\":\"\(s.id.uuidString.lowercased())\""
        out += ",\"start\":\(s.start),\"end\":\(s.end)"
        out += ",\"tip\":\"\(s.tip.rawValue)\",\"color\":\"\(s.color)\""
        out += ",\"dots\":["
        for (i, d) in s.dots.enumerated() {
            if i > 0 { out += "," }
            out += "[\(fmt(d.x, 2)),\(fmt(d.y, 2)),\(fmt(d.force, 3)),\(d.dt),\(opt(d.tiltX)),\(opt(d.tiltY)),\(opt(d.twist))]"
        }
        out += "]"
        out += ",\"src\":\"\(s.source.rawValue)\",\"pen\":\"\(escape(s.penMac))\",\"fw\":\"\(escape(s.firmware))\"}"
        return out
    }

    public static func metaLine(captured: Int, client: String, sdk: String) -> String {
        "{\"t\":\"meta\",\"captured\":\(captured),\"client\":\"\(escape(client))\",\"sdk\":\"\(escape(sdk))\"}"
    }

    static func fmt(_ v: Double, _ places: Int) -> String {
        let s = String(format: "%.\(places)f", v)
        // Trim trailing zeros but keep at least one digit after the point removed entirely if integer.
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t.isEmpty || t == "-" ? "0" : t
    }

    static func opt(_ v: Int?) -> String { v.map(String.init) ?? "null" }

    static func escape(_ s: String) -> String {
        var r = ""
        for c in s {
            switch c {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            default: r.append(c)
            }
        }
        return r
    }
}
