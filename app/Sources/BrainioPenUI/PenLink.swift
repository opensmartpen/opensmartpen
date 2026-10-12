import Foundation

/// Everything the panel and the settings window are allowed to know about the pens.
///
/// The real one is `PenSession`, which speaks to the hardware through the vendor SDK. This
/// protocol is what keeps that SDK on the far side of the wall: the views and the model are
/// written against plain values, so the whole UI layer builds — and can be looked at — with no
/// pen, no Bluetooth and no SDK linked in at all.
///
/// The only commands are the pairing ones. Reading is the UI's job; driving a pen is the app's.
public protocol PenLink: AnyObject {
    /// No pen can be reached, because Bluetooth itself cannot.
    var bluetoothOff: Bool { get }
    /// Every pen this Mac is connected or connecting to. A paired pen that is asleep is absent.
    var connections: [PenConnectionInfo] { get }
    /// The MACs of the pens this Mac accepts. A pen paired only by peripheral identifier is not
    /// listed until it has connected once and said its MAC.
    var pairedMacs: [String] { get }
    /// Looking for a new pen to pair, after `addPen()`.
    var isAdding: Bool { get }
    /// Pair the next unknown pen that is switched on near this Mac.
    func addPen()
    func cancelAdding()
    /// Stop accepting this pen, and let it go if it is connected. Its record in the notes repo
    /// stays, because strokes it has already written still name it.
    func forgetPen(mac: String)
}

/// One pen, as far as it has got with this Mac.
public struct PenConnectionInfo: Equatable {
    /// Lowercase and unpunctuated, as `PenRecord.mac`. Empty until the pen has said it.
    public let mac: String
    /// The name the pen reports for itself. Empty until it has said.
    public let name: String
    public let state: PenLinkState
    /// How far through pen memory we are, or nil when nothing is being copied.
    public let drain: DrainProgress?
    /// The last thing the pen said about itself, or nil when it has said nothing.
    public let reading: PenReport?
    /// When this pen last put a dot on paper. Which pen is "the one in your hand" when two are
    /// connected.
    public let lastDot: Date?

    public init(mac: String, name: String, state: PenLinkState, drain: DrainProgress?,
                reading: PenReport?, lastDot: Date?) {
        self.mac = mac
        self.name = name
        self.state = state
        self.drain = drain
        self.reading = reading
        self.lastDot = lastDot
    }

    /// The pen is here and talking. Readings are current only while this is true.
    public var isConnected: Bool {
        switch state {
        case .ready, .draining: return true
        default: return false
        }
    }
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
