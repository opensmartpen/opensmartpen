import Foundation

/// Ink colours and line widths, read from `palette.json` in the notes repo rather than held in
/// code, so the panel, the renderer and the pen's LED cannot disagree about what `red` looks like.
///
/// A name with no hex is unmeasured, not black: the printed swatch on the strip is markedly duller
/// than the ink it selects, so a colour can only be filled in by writing with it and measuring an
/// export. Callers decide what to do about a missing one; nothing here substitutes silently.
public struct Palette: Equatable {
    public static let relativePath = "palette.json"

    public private(set) var ink: [String: String] = [:]
    public private(set) var widthMM: [String: Double] = [:]
    /// Writing that resumes after this long a silence starts again at the defaults.
    public private(set) var resetAfterHours: Double = 24
    /// How pressure widens a line. Defined in the repo rather than in either codebase, so the
    /// renderer and anything drawing ink on screen cannot drift apart.
    public private(set) var pressureBase = 0.65
    public private(set) var pressureRange = 0.7
    public private(set) var typicalForce = 0.7

    public init() {}

    /// For a caller that has a palette in hand rather than a repo to read — the design window,
    /// and tests.
    public init(ink: [String: String], widthMM: [String: Double] = [:], resetAfterHours: Double = 24) {
        self.ink = ink
        self.widthMM = widthMM
        self.resetAfterHours = resetAfterHours
    }

    public static func load(root: URL) -> Palette {
        var p = Palette()
        guard let data = try? Data(contentsOf: root.appendingPathComponent(relativePath)),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return p }
        // null means "not measured yet", so it is dropped rather than stored as a colour.
        p.ink = (o["ink"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        p.widthMM = (o["width_mm"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        p.resetAfterHours = (o["reset_after_hours"] as? NSNumber)?.doubleValue ?? p.resetAfterHours
        if let q = o["pressure"] as? [String: Any] {
            p.pressureBase = (q["base"] as? NSNumber)?.doubleValue ?? p.pressureBase
            p.pressureRange = (q["range"] as? NSNumber)?.doubleValue ?? p.pressureRange
            p.typicalForce = (q["typical_force"] as? NSNumber)?.doubleValue ?? p.typicalForce
        }
        return p
    }

    public func hex(for ink: InkColor) -> String? { self.ink[ink.rawValue] }

    /// The inks this repo actually uses, in the strip's own order. A colour with no hex is not
    /// offered anywhere: the paper has ten buttons, and which of them mean anything is decided
    /// here rather than in code, so narrowing the set is an edit to one file.
    public var offered: [InkColor] {
        InkColor.allCases.filter { self.ink[$0.rawValue] != nil }
    }

    public func isOffered(_ colour: InkColor) -> Bool { self.ink[colour.rawValue] != nil }
    public func width(for width: LineWidth) -> Double? { widthMM[width.rawValue] }

    /// The width to draw, in mm, for a line of this weight pressed this hard. Force is 0...1.
    /// `width_mm` records the width at typical writing force, so this scales around that point:
    /// pressing harder than usual widens the line and lifting thins it, and the spread is gentle
    /// because a 0.5 mm nib does not double in width when pressed.
    public func width(for weight: LineWidth, force: Double) -> Double? {
        guard let drawn = width(for: weight) else { return nil }
        let f = max(0, min(1, force))
        return drawn * (pressureBase + pressureRange * f) / (pressureBase + pressureRange * typicalForce)
    }

    /// Red, green and blue 0...1, for a caller that has to compare colours rather than draw them.
    public func components(for ink: InkColor) -> (r: Double, g: Double, b: Double)? {
        guard var h = hex(for: ink) else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }
}
