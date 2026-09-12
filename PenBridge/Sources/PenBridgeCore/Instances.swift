import Foundation

/// Ncode section 3 gives a book code that identifies a **product**, not a physical copy. Two
/// identical A4 pads therefore report the same section, owner and book, and their page 1s are the
/// same address — so writing in a fresh pad would append to the previous pad's page files.
///
/// The unique identity has to be ours. A notebook record holds instances, each a slug and the
/// moment it started, and the derived layer routes a stroke to one by its timestamp. Raw capture
/// is untouched: mixed strokes are what the pen actually reported, and that file stays honest.
///
/// Because every stroke carries an absolute time and raw is append-only, a boundary can be applied
/// **retroactively**. Getting the date wrong is a re-render, not a loss — which is what lets
/// detection be imperfect, as long as it asks.
public struct BookInstance: Equatable, Codable {
    /// Directory name for this copy's rendered pages, e.g. `a4-pad-2`.
    public let slug: String
    /// Epoch milliseconds of the first stroke that belongs to this copy.
    public let startedAt: Int
    public var label: String?

    public init(slug: String, startedAt: Int, label: String? = nil) {
        self.slug = slug
        self.startedAt = startedAt
        self.label = label
    }
}

/// Why we think a fresh notebook was opened. Never acted on alone — a wrong silent guess merges
/// two notebooks into one file and would go unnoticed, so this only ever produces a question.
public struct InstanceSuspicion: Equatable {
    public enum Reason: String, Equatable {
        /// Ink appeared at the front of the book after the back had been reached. Revisiting an
        /// old page does not march forward from page 1; a new pad does.
        case sequenceRestart
        /// Nothing written in this book for a long time, and then a page far from where it stopped.
        case longGap
    }

    public let book: String
    public let reason: Reason
    public let at: Int
    public let previousPage: Int
    public let newPage: Int
}

/// Watches page arrivals for the two signals that a fresh copy was opened.
///
/// Deliberately cheap and deliberately timid. It holds one reading per book and produces at most
/// one suspicion per book until that question is answered, because a prompt you have declined
/// should not come back on the next stroke.
public final class InstanceWatcher {
    /// A book untouched for this long, resumed at a distant page, is worth a question.
    public static let longGapDays = 30.0
    /// How far the page number must move for a gap to count. Picking a notebook back up to
    /// annotate the page you left off on is not a new notebook.
    public static let pageJump = 10

    private struct Seen {
        var page: Int
        var at: Int
        var highWater: Int
    }

    private var seen: [String: Seen] = [:]
    private var asked: Set<String> = []

    public init() {}

    /// Feed every page as it is written to. Returns a question to ask, or nil.
    public func note(book: String, page: Int, at ms: Int) -> InstanceSuspicion? {
        guard let last = seen[book] else {
            seen[book] = Seen(page: page, at: ms, highWater: page)
            return nil
        }
        defer {
            seen[book] = Seen(page: page, at: ms, highWater: max(last.highWater, page))
        }
        guard !asked.contains(book) else { return nil }

        let days = Double(ms - last.at) / 86_400_000
        // Ink at the front of a book whose back has been reached. Returning to annotate an early
        // page happens, but it does not happen *after a silence* — the two together are the signal.
        if page <= 3, last.highWater >= Self.pageJump, days >= 1 {
            asked.insert(book)
            return InstanceSuspicion(book: book, reason: .sequenceRestart, at: ms,
                                     previousPage: last.page, newPage: page)
        }
        if days >= Self.longGapDays, abs(page - last.page) >= Self.pageJump {
            asked.insert(book)
            return InstanceSuspicion(book: book, reason: .longGap, at: ms,
                                     previousPage: last.page, newPage: page)
        }
        return nil
    }

    /// The question has been answered, either way. Asking again is only reasonable once something
    /// else has changed.
    public func resolve(book: String) { asked.remove(book) }
}
