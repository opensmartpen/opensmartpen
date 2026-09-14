import Foundation

/// Why the app decided that writing had moved into a fresh physical copy of a notebook.
///
/// Kept in `book.json` so a person who disagrees can see what the app saw, rather than guess at
/// it. The first copy of a product has none: it was not decided, it was simply the first.
public enum CopySignal: String, Codable, CaseIterable {
    /// New strokes land on ink that is already on the sheet. One sheet cannot hold the same
    /// writing twice, so this decides on its own.
    case inkOverlap = "ink-overlap"
    /// Ink appeared at the lowest written page again after the book had been written well past it,
    /// and a silence came before it. Coming back to annotate does not march forward from the front.
    case sequenceRestart = "sequence-restart"
}

/// Ink already on a page, coarsely: which cells of the sheet have been written in.
///
/// A bounding box would not do. Two pads written full overlap as boxes, and so do a page of notes
/// and one line added in its margin — the second is not a new notebook. Asking whether new dots
/// land *where old dots are* tells the two apart, and a grid is the cheapest way to ask it.
public struct InkGrid: Equatable {
    /// One bucket, in Ncode cells. About 2.4 mm, which is roughly the width of a stroke, so ink
    /// that crosses ink lands in the same bucket and ink beside it does not.
    public static let bucketCells = 1.0

    private var occupied: Set<Bucket> = []

    private struct Bucket: Hashable {
        let x: Int
        let y: Int
    }

    public init() {}

    public init(dots: some Sequence<DotSample>) {
        for d in dots { occupied.insert(Self.bucket(d)) }
    }

    public var isEmpty: Bool { occupied.isEmpty }

    public mutating func add(_ dots: some Sequence<DotSample>) {
        for d in dots { occupied.insert(Self.bucket(d)) }
    }

    /// The share of these dots that land on ink already here, 0 to 1.
    public func share(of dots: some Sequence<DotSample>) -> Double {
        var total = 0, hits = 0
        for d in dots {
            total += 1
            if occupied.contains(Self.bucket(d)) { hits += 1 }
        }
        return total == 0 ? 0 : Double(hits) / Double(total)
    }

    private static func bucket(_ d: DotSample) -> Bucket {
        Bucket(x: Int((d.x / bucketCells).rounded(.down)), y: Int((d.y / bucketCells).rounded(.down)))
    }
}

/// What the watcher is being asked about: strokes arriving on one page of one product.
public struct CopyEvidence {
    public let surface: String
    /// Ncode page, as the pen reported it.
    public let page: Int
    /// Epoch milliseconds of the first arriving stroke.
    public let at: Int
    /// The share of arriving dots that land on ink already in that page's file, 0 to 1.
    public let inkOverlap: Double

    public init(surface: String, page: Int, at: Int, inkOverlap: Double) {
        self.surface = surface
        self.page = page
        self.at = at
        self.inkOverlap = inkOverlap
    }
}

/// Decides whether a fresh physical copy of a notebook has been opened.
///
/// It decides rather than asks (ADR-002), and when the signals disagree it chooses the new copy:
/// a wrong split shows up as a second book and is repaired by moving pages, while a wrong merge
/// interleaves two notebooks inside one captured file and can only be repaired by cutting a file
/// we do not cut.
public final class CopyWatcher {
    /// How much of the arriving ink must land on ink already there. Well above what annotating
    /// between existing lines produces, and well below what writing the same sheet twice does.
    public static let overlapShare = 0.25
    /// A sequence restart counts only after a silence. A notebook finished this morning and
    /// started again this afternoon is one notebook.
    public static let restartSilenceDays = 1.0
    /// How far the book must have been written past its lowest page for a return to the front to
    /// mean anything. Coming back to page 2 of a book you are on page 3 of is not a new pad.
    public static let pageReach = 10

    private struct Seen {
        var lowest: Int
        var highWater: Int
        var at: Int
    }

    private var seen: [String: Seen] = [:]

    public init() {}

    /// Feed every page as strokes arrive for it. Returns the signal that decided a new copy, or
    /// nil to keep writing where we are.
    public func decide(_ e: CopyEvidence) -> CopySignal? {
        guard let last = seen[e.surface] else {
            seen[e.surface] = Seen(lowest: e.page, highWater: e.page, at: e.at)
            return nil
        }

        // Ink on ink decides alone. Nothing else has to agree, and nothing else can overrule it.
        if e.inkOverlap >= Self.overlapShare {
            seen[e.surface] = Seen(lowest: e.page, highWater: e.page, at: e.at)
            return .inkOverlap
        }

        let days = Double(e.at - last.at) / 86_400_000
        if e.page <= last.lowest, last.highWater - last.lowest >= Self.pageReach,
           days >= Self.restartSilenceDays {
            seen[e.surface] = Seen(lowest: e.page, highWater: e.page, at: e.at)
            return .sequenceRestart
        }

        seen[e.surface] = Seen(lowest: min(last.lowest, e.page),
                               highWater: max(last.highWater, e.page), at: e.at)
        return nil
    }

    /// Adopt what is already on disk, so a restart does not look like a fresh notebook and a
    /// long silence is measured from the last stroke rather than from launch.
    public func adopt(surface: String, pages: some Sequence<Int>, at ms: Int) {
        let list = Array(pages)
        guard let low = list.min(), let high = list.max() else { return }
        let existing = seen[surface]
        seen[surface] = Seen(lowest: min(low, existing?.lowest ?? low),
                             highWater: max(high, existing?.highWater ?? high),
                             at: max(ms, existing?.at ?? ms))
    }
}
