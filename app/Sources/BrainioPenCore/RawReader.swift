import Foundation

/// Reads back what `RawStore` wrote. The live view needs it so that opening the window mid-page
/// shows the ink already on the paper rather than an empty sheet.
///
/// Deliberately forgiving: a half-written last line (the file is appended to while this reads) or
/// a record shape it does not recognise is skipped, never thrown. A view that shows most of a page
/// beats one that shows an error.
public enum RawReader {
    public static func strokes(at url: URL) -> [Stroke] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        guard let page = PageID(rawRelativePath: url.pathComponents.suffix(5).joined(separator: "/"))
        else { return [] }

        var out: [Stroke] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let stroke = stroke(from: String(line), page: page) else { continue }
            out.append(stroke)
        }
        // Arrival order is not chronological: strokes made just before a connection completes come
        // back from pen memory after the first live ones. See docs/stroke-format.md.
        return out.sorted { $0.start < $1.start }
    }

    static func stroke(from line: String, page: PageID) -> Stroke? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["t"] as? String == "stroke",
              let start = obj["start"] as? Int,
              let rawDots = obj["dots"] as? [[Any]] else { return nil }

        let dots: [DotSample] = rawDots.compactMap { d in
            guard d.count >= 4 else { return nil }
            return DotSample(x: num(d[0]), y: num(d[1]), force: num(d[2]), dt: Int(num(d[3])),
                             tiltX: d.count > 4 ? int(d[4]) : nil,
                             tiltY: d.count > 5 ? int(d[5]) : nil,
                             twist: d.count > 6 ? int(d[6]) : nil)
        }
        guard !dots.isEmpty else { return nil }

        return Stroke(id: (obj["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                      page: page,
                      start: start,
                      end: obj["end"] as? Int ?? start,
                      tip: TipType(rawValue: obj["tip"] as? String ?? "") ?? .pen,
                      color: obj["color"] as? String ?? "#000000",
                      dots: dots,
                      source: StrokeSource(rawValue: obj["src"] as? String ?? "") ?? .live,
                      penMac: obj["pen"] as? String ?? "",
                      firmware: obj["fw"] as? String ?? "")
    }

    private static func num(_ v: Any) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
    private static func int(_ v: Any) -> Int? { (v as? NSNumber)?.intValue }
}

/// A page's drawable extent, in Ncode cells — the unit every raw coordinate is already in.
public struct PageGeometry: Equatable {
    /// One Ncode cell in millimetres. The pattern's own unit; see docs/stroke-format.md.
    public static let mmPerCell = 2.371

    public let widthCells: Double
    public let heightCells: Double

    public init(widthCells: Double, heightCells: Double) {
        self.widthCells = widthCells
        self.heightCells = heightCells
    }

    public init(widthMM: Double, heightMM: Double) {
        self.init(widthCells: widthMM / Self.mmPerCell, heightCells: heightMM / Self.mmPerCell)
    }

    /// A4, used when the notebook's own size is not recorded. Wrong-but-plausible beats refusing
    /// to draw: the strokes still land in the right relative places.
    public static let a4 = PageGeometry(widthMM: 210, heightMM: 297)

    public var aspectRatio: Double { widthCells / heightCells }
}
