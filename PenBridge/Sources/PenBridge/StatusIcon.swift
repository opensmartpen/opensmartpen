import AppKit

/// The menubar item's appearance. It is always the pencil — an app that turns into a battery
/// symbol when the battery is low disappears exactly when you go looking for it. State is carried
/// by what is added to the pencil, not by replacing it:
///
/// - plain pencil          connected, nothing waiting
/// - pencil with a drop    ink not yet synced: pages are waiting
/// - red pencil + percent  battery at or below the configured level, not charging
/// - dimmed pencil         PenBridge cannot work: Bluetooth off, or no permission for it
enum StatusIcon {
    struct Appearance {
        let image: NSImage
        let title: NSAttributedString
        let dimmed: Bool
        let tooltip: String
    }

    static func make(pendingPages: Int, battery: (percent: Int, low: Bool)?, working: Bool) -> Appearance {
        if let battery, battery.low {
            return Appearance(
                image: pencil(drop: pendingPages > 0, tint: .systemRed),
                title: NSAttributedString(string: " \(battery.percent)%",
                                          attributes: [.foregroundColor: NSColor.systemRed,
                                                       .font: NSFont.menuBarFont(ofSize: 0)]),
                dimmed: false,
                tooltip: "Pen battery \(battery.percent)% — charge it")
        }
        let tip: String
        switch (working, pendingPages) {
        case (false, _): tip = "PenBridge — Bluetooth is off or not permitted"
        case (_, 0): tip = "PenBridge — everything synced"
        case (_, 1): tip = "PenBridge — 1 page waiting to sync"
        case let (_, n): tip = "PenBridge — \(n) pages waiting to sync"
        }
        return Appearance(image: pencil(drop: pendingPages > 0, tint: nil),
                          title: NSAttributedString(string: ""),
                          dimmed: !working,
                          tooltip: tip)
    }

    /// A drop of ink beside the pencil stands for strokes that have not synced yet. The whole
    /// thing is one template image, so the menubar inverts it for us in light and dark.
    ///
    /// Drawn rather than taken from SF Symbols: the system `pencil` is a solid glyph, and the
    /// design is an outline one. Coordinates are the design's own 16-unit grid, with y flipped
    /// because AppKit draws upward and the drawing was authored downward.
    private static func pencil(drop: Bool, tint: NSColor?) -> NSImage {
        let side: CGFloat = 17
        let dropSize: CGFloat = 4.5
        let gap: CGFloat = 2
        let width = side + (drop ? gap + dropSize : 0)

        let image = NSImage(size: NSSize(width: width, height: side), flipped: false) { _ in
            let scale = side / 16
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: (16 - y) * scale) }

            let body = NSBezierPath()
            body.move(to: p(10.6, 2.4))
            body.line(to: p(3.4, 9.6))
            body.line(to: p(2.5, 13.5))
            body.line(to: p(6.4, 12.6))
            body.line(to: p(13.6, 5.4))
            body.close()

            let ferrule = NSBezierPath()
            ferrule.move(to: p(9.2, 3.8))
            ferrule.line(to: p(12.2, 6.8))

            (tint ?? .black).setStroke()
            for path in [body, ferrule] {
                path.lineWidth = 1.35 * scale
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }

            if drop {
                (tint ?? .black).setFill()
                NSBezierPath(ovalIn: NSRect(x: width - dropSize, y: (side - dropSize) / 2,
                                            width: dropSize, height: dropSize)).fill()
            }
            return true
        }
        image.isTemplate = tint == nil
        return image
    }
}
