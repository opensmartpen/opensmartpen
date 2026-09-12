import Foundation

/// Appends strokes to per-page JSONL files under the notes repository.
///
/// Deduplicates: the pen delivers the stroke in progress at connection time both from its memory and
/// live, identical dots with a few milliseconds of clock offset. A stroke is dropped when the same
/// page already holds one with the same dot count, same first and last dot, and a start within
/// `duplicateWindowMs`.
public final class RawStore {
    public let root: URL
    public var duplicateWindowMs = 500
    private let client: String
    private let sdk: String
    private let fm = FileManager.default

    private struct Signature: Equatable {
        let start: Int
        let dotCount: Int
        let first: (Double, Double)
        let last: (Double, Double)
        static func == (a: Signature, b: Signature) -> Bool {
            a.dotCount == b.dotCount && a.first == b.first && a.last == b.last
        }
        init(_ s: Stroke) {
            start = s.start
            dotCount = s.dots.count
            first = (s.dots.first?.x ?? 0, s.dots.first?.y ?? 0)
            last = (s.dots.last?.x ?? 0, s.dots.last?.y ?? 0)
        }
        init?(line: String) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["t"] as? String == "stroke",
                  let start = obj["start"] as? Int,
                  let dots = obj["dots"] as? [[Any]], let f = dots.first, let l = dots.last,
                  f.count >= 2, l.count >= 2 else { return nil }
            self.start = start
            dotCount = dots.count
            first = (Signature.num(f[0]), Signature.num(f[1]))
            last = (Signature.num(l[0]), Signature.num(l[1]))
        }
        static func num(_ v: Any) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
    }

    /// Signatures of strokes already on disk, per page, loaded lazily.
    private var known: [PageID: [Signature]] = [:]

    public init(root: URL, client: String, sdk: String) {
        self.root = root
        self.client = client
        self.sdk = sdk
    }

    public func fileURL(for page: PageID) -> URL {
        root.appendingPathComponent(page.rawRelativePath)
    }

    /// Append strokes, grouped by page. Creates the file with a meta line on first write.
    /// Returns the set of pages that received at least one new stroke.
    @discardableResult
    public func append(_ strokes: [Stroke], now: Date = Date()) throws -> Set<PageID> {
        var byPage: [PageID: [Stroke]] = [:]
        for s in strokes { byPage[s.page, default: []].append(s) }
        var touched: Set<PageID> = []
        for (page, list) in byPage {
            let url = fileURL(for: page)
            var seen = try loadSignatures(page)
            var text = ""
            let exists = fm.fileExists(atPath: url.path)
            for s in list.sorted(by: { $0.start < $1.start }) {
                let sig = Signature(s)
                if seen.contains(where: { $0 == sig && abs($0.start - sig.start) <= duplicateWindowMs }) {
                    Log.info("dropped duplicate \(s.source.rawValue) stroke at \(s.start) on \(page)")
                    continue
                }
                seen.append(sig)
                text += JSONL.strokeLine(s) + "\n"
            }
            known[page] = seen
            guard !text.isEmpty else { continue }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !exists {
                text = JSONL.metaLine(captured: Int(now.timeIntervalSince1970 * 1000), client: client, sdk: sdk) + "\n" + text
            }
            try appendAtomically(text, to: url)
            touched.insert(page)
        }
        return touched
    }

    /// Rounded coordinates as they will be written, so signatures compare equal after a round trip.
    private func loadSignatures(_ page: PageID) throws -> [Signature] {
        if let cached = known[page] { return cached }
        let url = fileURL(for: page)
        guard fm.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        let sigs = text.split(separator: "\n").compactMap { Signature(line: String($0)) }
        known[page] = sigs
        return sigs
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
