import Foundation

/// What the agent said when it was asked to carry one line out.
///
/// The reply itself is the deliverable — who somebody is, what the draft says, why it could not be
/// done — so it is kept whole. The one thing read out of it is a status line the prompt asks for,
/// because "is this finished" is the only part the app has to act on, and a model saying it in
/// plain words is a model the app would have to interpret.
public struct ActionAnswer: Equatable {
    public enum Status: String, Equatable {
        /// Carried out. The only status that ticks the box.
        case done
        /// The agent needs something only you can tell it.
        case needsInfo = "needs-info"
        /// It cannot be done from where the agent stands.
        case blocked
        /// The agent did not say. Treated as unfinished, because a tick is not something to guess.
        case unclear
    }

    public let status: Status
    /// Everything the agent said, with the status line taken off the end.
    public let text: String
    /// One line of it, for a row with no room for more.
    public let summary: String?

    public init(_ reply: String) {
        var lines = reply.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found: Status = .unclear
        // From the end: the prompt asks for it last, and a status named in passing halfway through
        // an explanation is not the agent's verdict.
        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let status = Self.status(in: line) else { break }
            found = status
            lines.remove(at: i)
            break
        }
        status = found
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        summary = Self.firstLine(of: text)
    }

    private static func status(in line: String) -> Status? {
        let lower = line.lowercased()
        guard let range = lower.range(of: "status:") else { return nil }
        // Anything before it has to be decoration — a bullet, a bold marker — not a sentence.
        guard lower[lower.startIndex..<range.lowerBound].allSatisfy({ "*-_# \t>".contains($0) })
        else { return nil }
        let value = lower[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " *_`.")) 
        switch value {
        case "done": return .done
        case "needs-info", "needs info", "needsinfo": return .needsInfo
        case "blocked": return .blocked
        default: return nil
        }
    }

    /// The first thing it said, short enough for one row. Markdown decoration is left alone: it is
    /// one line of a person's own notes, not a rendered document.
    private static func firstLine(of text: String) -> String? {
        guard let line = text.split(separator: "\n").map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces), !line.isEmpty
        else { return nil }
        guard line.count > 160 else { return line }
        return String(line.prefix(159)) + "…"
    }
}
