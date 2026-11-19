import Foundation

/// A page worked out in pixels, ready for something that can draw lines.
///
/// The arithmetic is here, in the domain, and the drawing is in the UI layer, because the two fail
/// in different ways: a wrong scale is a bug you can test for, and a wrong stroke join is something
/// you have to look at. This half is tested; the other half is small enough to read.
///
/// It took its crop and its pressure curve from an earlier Python renderer, `render.py`, which is
/// no longer in the repository. Every number it uses comes from `palette.json`, so a second
/// renderer that reads the same file cannot drift from it silently.
public struct PageRaster: Equatable {
    public struct Point: Equatable {
        /// Pixels from the left and top edge of the image.
        public let x: Double
        public let y: Double
        /// The width of the line at this point, in pixels.
        public let width: Double
    }

    public struct Line: Equatable {
        public let points: [Point]
        /// `#rrggbb`. An ink with no measured colour draws black rather than nothing.
        public let hex: String
    }

    public let widthPx: Int
    public let heightPx: Int
    public let lines: [Line]

    /// The ink width in millimetres when the palette has no measurement for the weight in force.
    /// What the refill actually lays down, as measured against Neo Studio; the 0.25 that the
    /// earlier Python renderer also used.
    public static let nibMM = 0.25

    /// White space around the writing, in millimetres.
    static let padMM = 6.0
    static let dpi = 200.0
    /// Sized for the transcriber, not for a person, which is where this parts company with the earlier
    /// Python renderer: its PNG was opened in Preview, this one is looked at by a model. A model scales anything
    /// longer than about 1568 pixels back down, so more than that is bytes spent on nothing; and
    /// under about 1100 a page with one line on it arrives small enough that the transcriber starts
    /// cropping and magnifying it to be sure, which costs minutes.
    static let maxPx = 1568.0
    static let minPx = 1100.0

    /// Work out the image for one page's strokes, cropped to the writing.
    ///
    /// Cropped, not the whole sheet: this image is read by a model, and a line of writing marooned
    /// in an A4 of white space transcribes badly. The SVG on the processing side keeps the true
    /// sheet, so nothing about the paper is lost — only about this picture of it.
    ///
    /// Returns nil when there is nothing to draw: an empty page, or one holding only eraser marks.
    public static func make(strokes: [Stroke], palette: Palette,
                            state: (Int) -> (ink: InkColor, width: LineWidth)) -> PageRaster? {
        let drawable = strokes.filter { $0.tip != .eraser && !$0.dots.isEmpty }
        guard !drawable.isEmpty else { return nil }

        let mm = PageGeometry.mmPerCell
        let xs = drawable.flatMap { $0.dots.map { $0.x * mm } }
        let ys = drawable.flatMap { $0.dots.map { $0.y * mm } }
        let x0 = xs.min()! - padMM, y0 = ys.min()! - padMM
        let x1 = xs.max()! + padMM, y1 = ys.max()! + padMM
        let widthMM = x1 - x0, heightMM = y1 - y0

        // Enough pixels for the handwriting to be legible, never so many that the image is mostly
        // cost. A page with one word on it is scaled up to the floor, a full A4 down to the ceiling.
        var scale = dpi / 25.4
        let longest = max(widthMM, heightMM) * scale
        if longest > maxPx { scale *= maxPx / longest }
        else if longest < minPx { scale *= minPx / longest }

        let lines: [Line] = drawable.map { stroke in
            let ink = state(stroke.start)
            let hex = palette.hex(for: ink.ink) ?? "#000000"
            let points = stroke.dots.map { dot -> Point in
                let widthMM = palette.width(for: ink.width, force: dot.force)
                    ?? nibMM * palette.pressureCurve(force: dot.force)
                return Point(x: (dot.x * mm - x0) * scale,
                             y: (dot.y * mm - y0) * scale,
                             width: max(1, widthMM * scale))
            }
            return Line(points: points, hex: hex)
        }

        return PageRaster(widthPx: max(1, Int((widthMM * scale).rounded())),
                          heightPx: max(1, Int((heightMM * scale).rounded())),
                          lines: lines)
    }
}

public extension Palette {
    /// How much wider than usual a line is at this force. Separate from `width(for:force:)` so a
    /// weight with no measured width can still vary with pressure instead of drawing flat.
    func pressureCurve(force: Double) -> Double {
        let f = max(0, min(1, force))
        return (pressureBase + pressureRange * f) / (pressureBase + pressureRange * typicalForce)
    }
}
