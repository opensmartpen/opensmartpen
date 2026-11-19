import Foundation

public enum DotEvent {
    case down
    case move
    case up
}

/// Turns the live dot stream into strokes. One instance per pen connection.
public final class StrokeAssembler {
    public struct Context {
        public var tip: TipType
        public var color: String
        public var penMac: String
        public var firmware: String
        public init(tip: TipType = .pen, color: String = "#000000", penMac: String, firmware: String) {
            self.tip = tip
            self.color = color
            self.penMac = penMac
            self.firmware = firmware
        }
    }

    private var current: (page: PageID, start: Int, last: Int, dots: [DotSample], ctx: Context)?

    public init() {}

    public var hasOpenStroke: Bool { current != nil }

    /// Feed one dot. `timeMs` is the absolute epoch time of the dot as computed by the SDK.
    /// Returns a finished stroke when this dot closes one.
    @discardableResult
    public func feed(event: DotEvent, page: PageID, sample: DotSample, timeMs: Int, context: Context) -> Stroke? {
        var finished: Stroke?
        switch event {
        case .down:
            // A Down while a stroke is open means we missed the Up. Close the old one first.
            if current != nil { finished = flush() }
            var first = sample
            first.dt = 0
            current = (page, timeMs, timeMs, [first], context)
        case .move:
            guard var c = current else {
                // Move without Down: start a stroke anyway so nothing is lost.
                var first = sample
                first.dt = 0
                current = (page, timeMs, timeMs, [first], context)
                return nil
            }
            if c.page != page {
                // Page changed mid-stroke: close and start a new one.
                finished = flush()
                var first = sample
                first.dt = 0
                current = (page, timeMs, timeMs, [first], context)
                return finished
            }
            c.dots.append(sample)
            c.last = timeMs
            current = c
        case .up:
            guard var c = current else { return nil }
            // The SDK's Up dot repeats the last coordinate; keep it only if it moved.
            if let lastDot = c.dots.last, lastDot.x != sample.x || lastDot.y != sample.y {
                c.dots.append(sample)
            }
            c.last = max(c.last, timeMs)
            current = c
            finished = flush()
        }
        return finished
    }

    /// Close the open stroke, if any (used on disconnect so nothing is lost).
    @discardableResult
    public func flush() -> Stroke? {
        guard let c = current else { return nil }
        current = nil
        return Stroke(page: c.page, start: c.start, end: c.last, tip: c.ctx.tip, color: c.ctx.color,
                      dots: c.dots, source: .live, penMac: c.ctx.penMac, firmware: c.ctx.firmware)
    }
}
