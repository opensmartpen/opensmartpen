import AppKit
import Foundation
import NISDK3
import BrainioPenCore

/// Conversions from NISDK3 types to the app's own model.
enum SDKMapping {
    static func page(_ p: PageInfo) -> PageID {
        PageID(section: p.section, owner: p.owner, book: p.note, page: p.page)
    }

    static func sample(_ d: Dot) -> DotSample {
        DotSample(x: Double(d.x), y: Double(d.y), force: Double(d.force), dt: Int(d.nTimeDelta),
                  tiltX: Int(d.xtilt), tiltY: Int(d.ytilt), twist: Int(d.twist))
    }

    static func event(_ t: DotType) -> DotEvent {
        switch t {
        case .Down: return .down
        case .Move: return .move
        case .Up: return .up
        }
    }

    static func tip(_ t: PenTipType) -> TipType {
        t == .Eraser ? .eraser : .pen
    }

    static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
        // The pen reports 0xFFFFFFFF ("no colour set") for live strokes; that is black ink, not white.
        if r == 255 && g == 255 && b == 255 { return "#000000" }
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    /// The pen's LED, which is the only colour NISDK3 can set — there is no ink colour command.
    /// Eight fixed values, so a chosen ink lands on whichever is nearest rather than on a
    /// hand-written table that would drift as palette.json gains measured colours.
    private static let ledColors: [(LEDColor, (Double, Double, Double))] = [
        (.VIOLET, (0.61, 0.25, 0.80)), (.BLUE, (0.24, 0.42, 0.94)),
        (.GRAY, (0.74, 0.74, 0.74)), (.YELLOW, (0.98, 0.80, 0.15)),
        (.PINK, (1.00, 0.13, 0.52)), (.MINT, (0.15, 0.88, 0.78)),
        (.RED, (0.98, 0.21, 0.06)), (.BLACK, (0.00, 0.00, 0.00)),
    ]

    static func led(nearest rgb: (r: Double, g: Double, b: Double)) -> LEDColor {
        ledColors.min {
            let a = ($0.1.0 - rgb.r, $0.1.1 - rgb.g, $0.1.2 - rgb.b)
            let b = ($1.1.0 - rgb.r, $1.1.1 - rgb.g, $1.1.2 - rgb.b)
            return a.0 * a.0 + a.1 * a.1 + a.2 * a.2 < b.0 * b.0 + b.1 * b.1 + b.2 * b.2
        }!.0
    }

    /// Strokes from one offline transfer packet.
    static func strokes(from data: OffLineData, penMac: String, firmware: String) -> [Stroke] {
        data.strokeArray.compactMap { s in
            guard !s.dotArray.isEmpty else { return nil }
            let page = PageID(section: Int(data.sectionId), owner: Int(data.ownerId), book: Int(data.noteId), page: Int(s.pageId))
            var dots: [DotSample] = []
            var t = s.downTime
            for (i, d) in s.dotArray.enumerated() {
                var sm = sample(d)
                if i == 0 { sm.dt = 0 } else { t += Int(d.nTimeDelta) }
                dots.append(sm)
            }
            return Stroke(page: page, start: s.downTime, end: t, tip: tip(s.penTipType), color: hex(s.penTipColor),
                          dots: dots, source: .offline, penMac: penMac, firmware: firmware)
        }
    }
}
