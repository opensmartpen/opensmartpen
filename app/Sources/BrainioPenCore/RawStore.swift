import Foundation

/// Appends strokes to one captured file for each page, inside the book copy that page belongs to
/// (ADR-002): `books/<copy>/raw/p12.jsonl`.
///
/// Deduplicates: the pen delivers the stroke in progress at connection time both from its memory and
/// live, identical dots with a few milliseconds of clock offset. A stroke is dropped when the same
/// page already holds one with the same dot count, same first and last dot, and a start within
/// `duplicateWindowMs`.
public final class RawStore {
    public let root: URL
    public var duplicateWindowMs = 500
    /// Which build wrote this file, for the header line. Not a client in the ADR-001 sense: the
    /// events in the file were produced by the pen, and each one says so.
    private let app: String
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

    /// What is already on a page: the strokes' signatures, for dedup, and where their ink is, for
    /// the question of whether a fresh copy of the notebook has been opened.
    private struct Page {
        var signatures: [Signature] = []
        var ink = InkGrid()
    }

    private var known: [PageRef: Page] = [:]

    public init(root: URL, app: String, sdk: String) {
        self.root = root
        self.app = app
        self.sdk = sdk
    }

    public func fileURL(for ref: PageRef) -> URL {
        root.appendingPathComponent(ref.rawRelativePath)
    }

    /// The share of these strokes' dots that land on ink already in this page's file, 0 to 1.
    /// Reading the file, not a guess: the question is whether one sheet is holding two notebooks.
    public func inkOverlap(_ strokes: [Stroke], with ref: PageRef) -> Double {
        let page = load(ref)
        guard !page.ink.isEmpty else { return 0 }
        return page.ink.share(of: strokes.flatMap(\.dots))
    }

    /// Ncode pages this copy already holds, for a watcher adopting what is on disk at launch.
    public func pages(in folder: BookFolder) -> [Int] {
        let dir = root.appendingPathComponent(folder.relativePath).appendingPathComponent("raw")
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { name in
            guard name.hasPrefix("p"), name.hasSuffix(".jsonl") else { return nil }
            return Int(name.dropFirst().dropLast(6))
        }
    }

    /// Append strokes to one copy, grouped by page. Creates each file with a meta line on first
    /// write. Returns the pages that received at least one new stroke.
    @discardableResult
    public func append(_ strokes: [Stroke], to folder: BookFolder, now: Date = Date()) throws -> Set<PageRef> {
        var byPage: [PageRef: [Stroke]] = [:]
        for s in strokes { byPage[PageRef(folder: folder, page: s.page), default: []].append(s) }
        var touched: Set<PageRef> = []
        for (ref, list) in byPage {
            let url = fileURL(for: ref)
            var page = load(ref)
            var text = ""
            let exists = fm.fileExists(atPath: url.path)
            for s in list.sorted(by: { $0.start < $1.start }) {
                let sig = Signature(s)
                if page.signatures.contains(where: { $0 == sig && abs($0.start - sig.start) <= duplicateWindowMs }) {
                    Log.info("dropped duplicate \(s.source.rawValue) stroke at \(s.start) on \(ref)")
                    continue
                }
                page.signatures.append(sig)
                page.ink.add(s.dots)
                text += JSONL.strokeLine(s) + "\n"
            }
            known[ref] = page
            guard !text.isEmpty else { continue }
            if !exists {
                text = JSONL.metaLine(captured: Int(now.timeIntervalSince1970 * 1000), app: app, sdk: sdk) + "\n" + text
            }
            try AppendOnlyFile.append(text, to: url)
            touched.insert(ref)
        }
        return touched
    }

    /// Rounded coordinates as they will be written, so signatures compare equal after a round trip.
    private func load(_ ref: PageRef) -> Page {
        if let cached = known[ref] { return cached }
        let url = fileURL(for: ref)
        var page = Page()
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let sig = Signature(line: String(line)) else { continue }
                page.signatures.append(sig)
            }
            page.ink.add(RawReader.strokes(in: text, page: ref.page).flatMap(\.dots))
        }
        known[ref] = page
        return page
    }
}
