import Foundation

/// How a page is described in the interface: a notebook name, and a page number only when the
/// notebook has been calibrated. `detail` is nil when the number would be a guess.
public struct PageLabel: Equatable {
    public let title: String
    public let detail: String?

    public init(title: String, detail: String?) {
        self.title = title
        self.detail = detail
    }

    /// One line, for places with no room for two.
    public var oneLine: String { detail.map { "\(title) · \($0)" } ?? title }
}

/// The pen's own storage, used to turn the SDK's "percent used" into something countable.
public enum PenMemory {
    /// Pages the A1 holds before it starts dropping strokes. NeoLAB's figure; not measured here.
    public static let capacityPages = 160

    public static func pages(usedPercent: Int) -> Int {
        Int((Double(usedPercent) / 100 * Double(capacityPages)).rounded())
    }
}
