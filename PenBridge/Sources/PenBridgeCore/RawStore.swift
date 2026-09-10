import Foundation

/// Appends strokes to per-page JSONL files under the notes repository.
public final class RawStore {
    public let root: URL
    private let client: String
    private let sdk: String
    private let fm = FileManager.default

    public init(root: URL, client: String, sdk: String) {
        self.root = root
        self.client = client
        self.sdk = sdk
    }

    public func fileURL(for page: PageID) -> URL {
        root.appendingPathComponent(page.rawRelativePath)
    }

    /// Append strokes, grouped by page. Creates the file with a meta line on first write.
    /// Returns the set of pages touched.
    @discardableResult
    public func append(_ strokes: [Stroke], now: Date = Date()) throws -> Set<PageID> {
        var byPage: [PageID: [Stroke]] = [:]
        for s in strokes { byPage[s.page, default: []].append(s) }
        for (page, list) in byPage {
            let url = fileURL(for: page)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var text = ""
            if !fm.fileExists(atPath: url.path) {
                text += JSONL.metaLine(captured: Int(now.timeIntervalSince1970 * 1000), client: client, sdk: sdk) + "\n"
            }
            for s in list.sorted(by: { $0.start < $1.start }) {
                text += JSONL.strokeLine(s) + "\n"
            }
            try appendAtomically(text, to: url)
        }
        return Set(byPage.keys)
    }

    private func appendAtomically(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        if !fm.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}
