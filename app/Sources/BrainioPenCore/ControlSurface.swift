import Foundation

/// The ink colour a mark is meant to have. The pen cannot be told this — NISDK3 has no ink
/// colour command, only `requestSetPenLEDColor` — so it is our state, not the pen's, and every
/// stroke still arrives stamped black. Hex values live in the repo's palette.json, not here:
/// the name is the decision, the colour is a rendering of it.
public enum InkColor: String, CaseIterable, Codable {
    case white, black, grey, yellow, orange
    case red, blue, green, purple, navy
}

/// How wide a mark is meant to be drawn. `default` is the state before anything is tapped;
/// the strip itself only offers the other three.
public enum LineWidth: String, CaseIterable, Codable {
    case thin, `default`, medium, thick
}

public enum ControlButton: Equatable {
    case ink(InkColor)
    case width(LineWidth)
}

/// Decodes a tap on the LAMY paper controller (Ncode book s3/o1013/b1) into a button.
///
/// The strip is ordinary Ncode paper: tapping it produces a stroke like any other, and the pen
/// acts on none of it. Every coordinate below was measured from real taps, in Ncode cells.
///
/// A tap is matched to the nearest column and then the nearest row, rather than to a printed
/// rectangle. The columns are about four cells apart and the rows four to seven, so a centre
/// that is off by a cell still lands on the right button — which matters, because the left
/// colour column's position is estimated from a photograph and has never been confirmed by a
/// tap. Anything far from every button is refused rather than guessed at.
public enum ControlMap {
    static let linesColumnX = 9.8
    static let colorsLeftX = 15.9   // estimated from the photo; unconfirmed by a tap
    static let colorsRightX = 20.0

    /// Line width buttons, top to bottom.
    static let lineRows: [(y: Double, width: LineWidth)] = [
        (46.3, .thin), (52.9, .medium), (60.1, .thick),
    ]

    /// Colour swatch rows, top to bottom. Rows 4 and 5 are extrapolated from the 4.7 cell pitch.
    static let colorRows: [Double] = [43.9, 48.3, 53.2, 57.8, 62.4]
    static let leftColumnInks: [InkColor] = [.white, .black, .grey, .yellow, .orange]
    static let rightColumnInks: [InkColor] = [.red, .blue, .green, .purple, .navy]

    /// How far a tap may sit from a button's centre and still count, in cells. Half the smallest
    /// pitch, so neighbouring buttons cannot both claim a tap.
    static let tolerance = 2.3

    /// The button a tap at these cell coordinates means, or nil if it lands on no button.
    public static func button(atX x: Double, y: Double) -> ControlButton? {
        let columns: [(x: Double, isLines: Bool, inks: [InkColor])] = [
            (linesColumnX, true, []),
            (colorsLeftX, false, leftColumnInks),
            (colorsRightX, false, rightColumnInks),
        ]
        guard let column = columns.min(by: { abs($0.x - x) < abs($1.x - x) }),
              abs(column.x - x) <= tolerance else { return nil }

        if column.isLines {
            guard let row = lineRows.min(by: { abs($0.y - y) < abs($1.y - y) }),
                  abs(row.y - y) <= tolerance else { return nil }
            return .width(row.width)
        }
        guard let index = colorRows.indices.min(by: { abs(colorRows[$0] - y) < abs(colorRows[$1] - y) }),
              abs(colorRows[index] - y) <= tolerance else { return nil }
        return .ink(column.inks[index])
    }

    /// The button a tap stroke means. Uses the mean of its dots: a tap is a blot, not a line.
    public static func button(for stroke: Stroke) -> ControlButton? {
        guard !stroke.dots.isEmpty else { return nil }
        let n = Double(stroke.dots.count)
        return button(atX: stroke.dots.reduce(0) { $0 + $1.x } / n,
                      y: stroke.dots.reduce(0) { $0 + $1.y } / n)
    }
}
