import Foundation

/// What is known about a page's transcript.
public enum Transcript: Equatable {
    /// The text, as Markdown.
    case text(String)
    /// Nobody has transcribed this page yet.
    case none
    /// It could not be fetched, and there is no copy on this Mac to show instead.
    case unavailable(String)
}

/// Fetches the transcripts that whatever reads the bucket writes back into it.
///
/// The app does not transcribe. It uploads a page, something else reads it and stores the text at
/// `transcripts/<copy>/p<N>.md`, and this brings that one file back so the viewer can show it
/// beside the ink. That is the only thing the app ever reads from the bucket, it is read by name
/// — nothing is listed — and nothing is ever written under `transcripts/`.
///
/// Each transcript fetched is kept under the notes folder at the same path, so a page read once
/// can be read again on a train.
public final class TranscriptStore {
    private let root: URL
    private let client: () -> S3Client?
    private let queue = DispatchQueue(label: "org.opensmartpen.app.transcripts")

    public init(root: URL, client: @escaping () -> S3Client?) {
        self.root = root
        self.client = client
    }

    /// Where a page's transcript is, in the bucket and under the notes folder alike.
    public static func path(for page: PageRef) -> String {
        "transcripts/\(page.folder.name)/p\(page.number).md"
    }

    /// The copy on this Mac, if the page has been fetched before. Never touches the network.
    public func cached(for page: PageRef) -> Transcript {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(Self.path(for: page))),
              let text = String(data: data, encoding: .utf8) else { return .none }
        return .text(text)
    }

    /// Ask the bucket, off the main thread, and answer on it. With no bucket connected, or none
    /// reachable, the answer is whatever is already on this Mac.
    public func fetch(for page: PageRef, completion: @escaping (Transcript) -> Void) {
        queue.async { [self] in
            let answer = load(page)
            DispatchQueue.main.async { completion(answer) }
        }
    }

    func load(_ page: PageRef) -> Transcript {
        let kept = cached(for: page)
        guard let client = client() else { return kept }
        let path = Self.path(for: page)
        // Timed, and never named: which page it was is not said, and neither is its text.
        let span = Telemetry.begin("transcript.fetch", ["transcript.cached": .bool(kept != .none)])
        do {
            guard let data = try client.get(path), let text = String(data: data, encoding: .utf8) else {
                span.set("transcript.state", "none")
                span.end()
                return kept
            }
            span.set("transcript.state", "text")
            span.set("transcript.size", .int(data.count))
            span.end()
            let url = root.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            return .text(text)
        } catch {
            span.set("transcript.state", "unavailable")
            span.end(error: Telemetry.describe(error))
            // A copy that may be a little old is better than an error over a page of text.
            if case .text = kept { return kept }
            return .unavailable((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}
