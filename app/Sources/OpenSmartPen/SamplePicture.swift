import AppKit

/// The picture of the sample page: a short list in a hand-like typeface.
///
/// A stand-in. It is drawn from a font, so it is easier to read than real handwriting and proves
/// less. The real sample will be a page written with a pen, kept as its strokes and drawn like
/// every other page; this goes when that page exists.
enum SamplePicture {
    private static let lines: [(done: Bool, text: String)] = [
        (false, "Buy milk"),
        (false, "Call mom"),
        (true, "Teach the pen to read"),
        (false, "Take over the world (after lunch)"),
    ]

    static func png() -> Data? {
        let width = 1200, height = 760
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.black.setStroke()

        func font(_ size: CGFloat) -> NSFont {
            NSFont(name: "BradleyHandITCTT-Bold", size: size) ?? NSFont(name: "Noteworthy-Bold", size: size)
                ?? .systemFont(ofSize: size)
        }
        func draw(_ text: String, at point: NSPoint, size: CGFloat) {
            NSAttributedString(string: text, attributes: [.font: font(size), .foregroundColor: NSColor.black])
                .draw(at: point)
        }

        // AppKit counts y up from the bottom, so the first line is the highest.
        var y = CGFloat(height) - 150
        draw("TODO", at: NSPoint(x: 90, y: y), size: 84)
        y -= 120
        for line in lines {
            let box = NSBezierPath(rect: NSRect(x: 96, y: y + 14, width: 44, height: 44))
            box.lineWidth = 4
            box.stroke()
            if line.done {
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: 102, y: y + 38))
                tick.line(to: NSPoint(x: 116, y: y + 20))
                tick.line(to: NSPoint(x: 150, y: y + 70))
                tick.lineWidth = 6
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                tick.stroke()
            }
            draw(line.text, at: NSPoint(x: 172, y: y), size: 58)
            y -= 110
        }
        return rep.representation(using: .png, properties: [:])
    }
}
