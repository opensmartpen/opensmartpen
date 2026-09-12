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

        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let scale = side / 16
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: (16 - y) * scale) }

            // Exactly the path in the design, on its own 16-unit grid, with y flipped because
            // AppKit draws upward and the drawing was authored downward.
            let body = NSBezierPath()
            body.move(to: p(11.2, 1.6))
            body.line(to: p(14.4, 4.8))
            body.line(to: p(5.6, 13.6))
            body.line(to: p(1.9, 14.5))
            body.line(to: p(2.8, 10.8))
            body.close()

            let ferrule = NSBezierPath()
            ferrule.move(to: p(9.6, 3.2))
            ferrule.line(to: p(12.8, 6.4))

            NSColor.labelColor.setStroke()
            for path in [body, ferrule] {
                path.lineWidth = 1.35 * scale
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }

            // The drop sits in the corner the pencil leaves empty, inside the same square: beside
            // it the mark would be wider than every other menubar item and shift when it appeared.
            //
            // Waiting pages draw it in the pencil's own ink rather than in violet. The menubar is
            // tinted by whatever wallpaper is behind it, so no single hue stays legible there —
            // violet on a pink desktop is nearly invisible. As a template the whole mark is
            // recoloured by AppKit to contrast with whatever it is sitting on, every time. The
            // signal is that a drop is there at all, which survives any background; violet still
            // does its job in the panel, where we own the surface it sits on.
            if drop || tint != nil {
                (tint ?? .black).setFill()
                let r: CGFloat = 2.3 * scale
                let c = p(3, 3)
                NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
            }
            return true
        }
        // A red battery is a colour we mean; everything else is a template so the menubar can
        // decide what contrasts with it.
        image.isTemplate = tint == nil
        return image
    }
}
