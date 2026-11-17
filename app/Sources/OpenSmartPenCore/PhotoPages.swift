import Foundation

/// Pages that arrive as a picture, not as strokes: a photo of a sheet of paper.
///
/// They live in one notebook the app makes itself, "Photos", and each new picture is its next
/// page. The picture as it arrived is the record, kept in `raw/` beside a small `.jsonl` file
/// that names it. That file is what makes a photo an ordinary page to everything else: it is
/// what is found unsent, what waits to be uploaded, and what the page picture is made from, by
/// the same code that does those things for a page of strokes.
///
/// The notebook has an address in the pen's own form, one no paper is printed with, so that it
/// is filed, named and opened like a notebook. The address means nothing.
public enum PhotoPages {
    public static let surface = "s0/o0/b0"
    public static let title = "Photos"

    /// File a picture as the next page. The picture is written first and the file that names it
    /// second, so a page that can be seen always has its picture. Returns the page, or nil when
    /// nothing could be written.
    ///
    /// `taken` is when the photo was taken, when that is known. It is written beside `added`,
    /// the moment the picture was filed, because the two can be far apart: a photo from last week
    /// added today. Neither is when the page was written; a photo does not say.
    public static func add(image: Data, ext: String, taken: Date? = nil, books: BookRegistry, root: URL,
                           app: String, now: Date = Date()) -> PageRef? {
        guard let first = PageID(surface: surface, page: 1) else { return nil }
        let isNew = books.current(for: surface) == nil
        guard var record = books.ensureRecord(for: first) else { return nil }
        if isNew {
            record.title = title
            guard books.save(record) else { return nil }
        }
        let folder = record.folder
        let rawDirectory = root.appendingPathComponent(folder.relativePath).appendingPathComponent("raw")
        let number = (pageNumbers(in: rawDirectory).max() ?? 0) + 1
        guard let id = PageID(surface: surface, page: number) else { return nil }
        let ref = PageRef(folder: folder, page: id)
        let name = "p\(number).\(ext.lowercased())"
        let ms = Int(now.timeIntervalSince1970 * 1000)
        let lines = JSONL.metaLine(captured: ms, app: app, sdk: "") + "\n"
            + "{\"t\":\"image\",\"file\":\"\(name)\",\"added\":\(ms)"
            + (taken.map { ",\"taken\":\(Int($0.timeIntervalSince1970 * 1000))" } ?? "") + "}\n"
        do {
            try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
            try image.write(to: rawDirectory.appendingPathComponent(name), options: .atomic)
            try Data(lines.utf8).write(to: root.appendingPathComponent(ref.rawRelativePath), options: .atomic)
        } catch {
            Log.error("could not file a photo as \(ref): \(error)")
            return nil
        }
        return ref
    }

    /// The picture a page was filed with, when the page is a photo. Nil for a page of strokes.
    public static func image(of ref: PageRef, root: URL) -> URL? {
        let raw = root.appendingPathComponent(ref.rawRelativePath)
        guard let text = try? String(contentsOf: raw, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["t"] as? String == "image", let file = obj["file"] as? String,
                  // A name, never a path: the picture is beside the file that names it.
                  !file.contains("/"), !file.hasPrefix(".") else { continue }
            return raw.deletingLastPathComponent().appendingPathComponent(file)
        }
        return nil
    }

    private static func pageNumbers(in directory: URL) -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix("p"), name.hasSuffix(".jsonl") else { return nil }
            return Int(name.dropFirst().dropLast(6))
        }
    }
}
