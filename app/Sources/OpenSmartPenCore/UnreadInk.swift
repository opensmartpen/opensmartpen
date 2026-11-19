import Foundation

/// Counts the samples a pen took and could not read.
///
/// The pen photographs the paper's pattern about 120 times a second and works out where it is from
/// each picture. When a picture cannot be decoded — the angle, a dirty lens, paper with no pattern
/// — it sends an error in place of a dot, and no stroke is ever made of it. Nothing is stored in
/// pen memory either: the pen was connected, so as far as it knows it delivered what it had. The
/// writing is on the paper and nowhere else.
///
/// That used to go to the debug log, which is off, so ink went missing with nothing to show for it
/// (2026-11-11: fourteen minutes the pen knew about and the app did not). The errors arrive at the
/// rate of the samples, so they are counted over a short window and reported once, not one a line.
public struct UnreadInk {
    public struct Report: Equatable {
        public let count: Int
        /// How many of each of the pen's own error codes, for whoever has to work out why.
        public let codes: [UInt8: Int]
        public let since: Date
        /// Enough lost in one window that a word or more is likely missing, not a full stop.
        public let worthTelling: Bool

        public var line: String {
            let byCode = codes.sorted { $0.key < $1.key }.map { "code \($0.key) ×\($0.value)" }
                .joined(separator: ", ")
            return "\(count) sample(s) the pen could not read (\(byCode))"
        }
    }

    /// How long errors are gathered before they are reported together.
    public static let window: TimeInterval = 10
    /// A guess, to be corrected by what the log shows: a stray error or two is ordinary writing,
    /// and a quarter of a second of them is not.
    public static let tellingCount = 30

    private var count = 0
    private var codes: [UInt8: Int] = [:]
    private var since: Date?

    public init() {}

    /// Note one error. True when it is the first of a window, which is when to start the clock.
    @discardableResult
    public mutating func record(code: UInt8, at now: Date = Date()) -> Bool {
        let first = since == nil
        if first { since = now }
        count += 1
        codes[code, default: 0] += 1
        return first
    }

    /// What has gathered, and start again. Nil when nothing has.
    public mutating func take() -> Report? {
        guard let since, count > 0 else { return nil }
        let report = Report(count: count, codes: codes, since: since,
                            worthTelling: count >= Self.tellingCount)
        self = UnreadInk()
        return report
    }
}
