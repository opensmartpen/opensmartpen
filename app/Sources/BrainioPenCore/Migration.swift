import Foundation

/// Moves a pre-ADR-002 notes repository into the layout ADR-002 describes.
///
/// The old layout keyed everything by product: `raw/s3/o27/b450/p12.jsonl` for capture, a flat
/// `books/<slug>.json` for the record, and `pages/<slug>/` for the readable files. The new one
/// gives each physical copy a folder of its own.
///
/// Files are **copied**, and the old repository is left exactly as it is. A move is not worth the
/// risk here: the old directory is a git repository holding the only copy of some strokes, and a
/// person who wants it gone can delete it once they have seen that the new one is right.
public enum DataMigration {
    /// Copy `old` into `new` in the new layout. Does nothing when `new` already holds books, so
    /// running it on every launch is safe.
    @discardableResult
    public static func adoptLegacyRepo(from old: URL, to new: URL) -> Bool {
        let fm = FileManager.default
        let books = new.appendingPathComponent("books")
        guard !fm.fileExists(atPath: books.path),
              fm.fileExists(atPath: old.appendingPathComponent("raw").path)
                  || fm.fileExists(atPath: old.appendingPathComponent("books").path)
        else { return false }

        Log.info("adopting notes from \(old.path) into \(new.path) (ADR-002 layout)")
        do {
            try fm.createDirectory(at: books, withIntermediateDirectories: true)

            // One folder for each product. Two copies of a product could only be told apart by a
            // date inside the old record, and separating them would mean cutting a captured file
            // in two — which ADR-002 forbids. So each product becomes one copy, and a second is
            // decided from here on by the evidence rather than backwards from a guess.
            var folders: [String: BookFolder] = [:]
            var records: [String: BookRecord] = [:]

            for (surface, legacy) in legacyRecords(in: old) {
                let folder = BookFolder(surface: surface,
                                        id: BookFolder.generateID(taken: Set(folders.values.map(\.id))))
                folders[surface] = folder
                records[surface] = BookRecord(folder: folder, title: legacy.title,
                                              firstPage: legacy.firstPage,
                                              widthMM: legacy.widthMM, heightMM: legacy.heightMM,
                                              binding: legacy.binding)
                if legacy.instanceCount > 1 {
                    Log.warn("\(legacy.slug) recorded \(legacy.instanceCount) copies; they become one copy, "
                             + "because separating them would mean cutting a captured file")
                }
            }

            // Capture first: a page whose book was never recorded still has to arrive somewhere.
            for (surface, page, file) in legacyPages(in: old) {
                let folder: BookFolder
                if let known = folders[surface] { folder = known } else {
                    let known = KnownBooks.product(forSurface: surface)
                    let fresh = BookFolder(surface: surface,
                                           id: BookFolder.generateID(taken: Set(folders.values.map(\.id))))
                    folders[surface] = fresh
                    records[surface] = BookRecord(
                        folder: fresh,
                        title: known?.title ?? KnownBooks.fallbackTitle(widthMM: known?.widthMM,
                                                                        heightMM: known?.heightMM),
                        firstPage: known?.firstPage ?? 1,
                        widthMM: known?.widthMM, heightMM: known?.heightMM,
                        binding: known?.binding ?? .pad)
                    folder = fresh
                }
                try copy(file, to: new.appendingPathComponent(folder.rawPath(page: page)), fm: fm)
            }

            for (surface, record) in records {
                let file = new.appendingPathComponent(record.folder.recordPath)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try record.json.write(to: file, options: .atomic)
                // Readable files come across only because deleting them would make the app look
                // empty until something renders again. Nothing is lost if they do not arrive.
                if let slug = legacySlug(for: surface, in: old) {
                    try? copyTree(old.appendingPathComponent("pages/\(slug)"),
                                  to: new.appendingPathComponent("\(record.folder.relativePath)/pages"), fm: fm)
                }
            }

            // A setting has no surface, so it sits at the root now rather than under `raw/`.
            try? copy(old.appendingPathComponent("raw/mode.jsonl"),
                      to: new.appendingPathComponent(ModeLog.relativePath), fm: fm)
            try? copyTree(old.appendingPathComponent("pens"),
                          to: new.appendingPathComponent("pens"), fm: fm)
            try? copy(old.appendingPathComponent("palette.json"),
                      to: new.appendingPathComponent("palette.json"), fm: fm)

            Log.info("adopted \(records.count) notebook(s); \(old.path) was left untouched")
            return true
        } catch {
            Log.error("adopting notes from \(old.path) failed: \(error)")
            return false
        }
    }

    // MARK: - Reading the old layout

    struct LegacyBook {
        let slug: String
        let title: String
        let firstPage: Int
        let widthMM: Double?
        let heightMM: Double?
        let binding: KnownBooks.Binding
        let instanceCount: Int
    }

    private struct LegacyPayload: Codable {
        var id: String?
        var title: String?
        var first_page: Int?
        var width_mm: Double?
        var height_mm: Double?
        var binding: String?
        var instances: [Instance]?
        struct Instance: Codable { var slug: String?; var startedAt: Int? }
    }

    static func legacyRecords(in old: URL) -> [(String, LegacyBook)] {
        let dir = old.appendingPathComponent("books")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        return files.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let p = try? JSONDecoder().decode(LegacyPayload.self, from: data),
                  let surface = p.id else { return nil }
            let slug = file.deletingPathExtension().lastPathComponent
            return (surface, LegacyBook(
                slug: slug, title: p.title ?? slug, firstPage: p.first_page ?? 1,
                widthMM: p.width_mm, heightMM: p.height_mm,
                binding: p.binding.flatMap(KnownBooks.Binding.init(rawValue:)) ?? .pad,
                instanceCount: p.instances?.count ?? 1))
        }
    }

    static func legacySlug(for surface: String, in old: URL) -> String? {
        legacyRecords(in: old).first { $0.0 == surface }?.1.slug
    }

    /// Every captured page in the old tree, as (surface identity, Ncode page, file).
    static func legacyPages(in old: URL) -> [(String, Int, URL)] {
        let raw = old.appendingPathComponent("raw")
        guard let walker = FileManager.default.enumerator(at: raw, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var out: [(String, Int, URL)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let parts: [String] = Array(url.pathComponents.suffix(4))
            guard parts.count == 4, parts[0].hasPrefix("s"), parts[1].hasPrefix("o"),
                  parts[2].hasPrefix("b"), parts[3].hasPrefix("p"),
                  let page = Int(parts[3].dropFirst().dropLast(6)) else { continue }
            out.append((parts[0..<3].joined(separator: "/"), page, url))
        }
        return out
    }

    private static func copy(_ from: URL, to: URL, fm: FileManager) throws {
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return }
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: from, to: to)
    }

    private static func copyTree(_ from: URL, to: URL, fm: FileManager) throws {
        guard fm.fileExists(atPath: from.path) else { return }
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: from.path) where !name.hasPrefix(".") {
            try copy(from.appendingPathComponent(name), to: to.appendingPathComponent(name), fm: fm)
        }
    }
}
