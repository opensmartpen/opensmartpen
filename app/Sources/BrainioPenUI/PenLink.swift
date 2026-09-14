import Foundation

/// Everything the panel is allowed to know about the pen.
///
/// The real one is `PenSession`, which speaks to the hardware through the vendor SDK. This
/// protocol is what keeps that SDK on the far side of the wall: the views and the model are
/// written against plain values, so the whole UI layer builds — and can be looked at — with no
/// pen, no Bluetooth and no SDK linked in at all.
///
/// Nothing here is a command except `forgetPen`. Reading is the panel's job; driving the pen is
/// the app's.
public protocol PenLink: AnyObject {
    /// The name the pen reports for itself. Empty until it has said.
    var penName: String { get }
    /// The pen is here and talking. Readings are current only while this is true.
    var isConnected: Bool { get }
    var linkState: PenLinkState { get }
    /// How far through pen memory we are, or nil when nothing is being copied.
    var drainProgress: DrainProgress? { get }
    /// The last thing the pen said about itself, or nil when it has said nothing.
    var reading: PenReport? { get }
    /// Unpair, so the next pen seen becomes the paired one.
    func forgetPen()
}

/// Where the connection is. Not the same question as "is my writing safe", which the panel's own
/// status answers — after five idle minutes those two stop agreeing.
public enum PenLinkState: Equatable {
    case bluetoothOff
    case scanning
    case connecting
    case authorizing
    case ready
    case draining(remaining: Int)
}

/// The SDK reports a percentage per notebook, so this is per-notebook progress plus which
/// notebook we are on.
public struct DrainProgress: Equatable {
    public let index: Int
    public let count: Int
    public let percent: Int

    public init(index: Int, count: Int, percent: Int) {
        self.index = index
        self.count = count
        self.percent = percent
    }
}

/// One report from the pen, in plain numbers. The SDK's own settings struct stops here.
public struct PenReport: Equatable {
    public let battery: Int
    public let charging: Bool
    /// How full the pen's offline memory is, as a percentage.
    public let memoryUsedPercent: Int

    public init(battery: Int, charging: Bool, memoryUsedPercent: Int) {
        self.battery = battery
        self.charging = charging
        self.memoryUsedPercent = memoryUsedPercent
    }
}
