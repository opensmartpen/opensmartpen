import Foundation

/// Where one physical copy of a notebook lives: `books/s3-o27-b450-7f3a9c`.
///
/// A book code identifies a *product*, not a copy — two identical A4 pads report the same
/// section, owner and book, so their page 1s share an address. The copy is ours to name, and
/// this is the name: the client's own surface identity, so a person can read it, followed by an
/// id we generated, so two copies of one product cannot collide (ADR-002).
///
/// The id is opaque. Nothing reads meaning out of it, and nothing derives it from anything —
/// which is what lets a title change without a file moving, and a page move without its content
/// changing.
public struct BookFolder: Hashable, CustomStringConvertible {
    /// The surface identity the client reported, in the client's own form. For the pen that is
    /// an Ncode address without the page, `s3/o27/b450`. Another client would bring its own.
    public let surface: String
    /// Six characters, `0`–`9` and `a`–`f`. Generated, never derived.
    public let id: String

    public init(surface: String, id: String) {
        self.surface = surface
        self.id = id
    }

    /// Directory name: the surface identity with `/` replaced by `-`, then the id.
    public var name: String { Self.flatten(surface) + "-" + id }

    public var description: String { name }

    public var relativePath: String { "books/\(name)" }

    /// The copy's own record — the only authority on what this notebook is.
    public var recordPath: String { "\(relativePath)/book.json" }

    /// A captured page keeps the name its own client used, so `p4.jsonl` is Ncode page 4 and
    /// stays page 4 however a person counts it (ADR-002).
    public func rawPath(page: Int) -> String { "\(relativePath)/raw/p\(page).jsonl" }

    /// A readable file carries the same page name as the captured one it was made from.
    public func pagePath(stem: String, ext: String) -> String { "\(relativePath)/pages/\(stem).\(ext)" }

    /// Parse a directory name back. Nil when the trailing id is not one of ours, so a folder
    /// somebody created by hand cannot be mistaken for a book.
    public init?(name: String) {
        guard let dash = name.lastIndex(of: "-") else { return nil }
        let id = String(name[name.index(after: dash)...])
        guard Self.isID(id) else { return nil }
        let flat = String(name[..<dash])
        guard !flat.isEmpty else { return nil }
        self.init(surface: Self.unflatten(flat), id: id)
    }

    // MARK: - Ids

    public static let idLength = 6
    private static let alphabet = Array("0123456789abcdef")

    /// A free id. Six hex characters are 16 million values, so a collision is not the reason for
    /// the check — an id reused after a folder was restored from a backup is.
    public static func generateID(taken: Set<String> = []) -> String {
        for _ in 0..<100 {
            let id = String((0..<idLength).map { _ in alphabet.randomElement()! })
            if !taken.contains(id) { return id }
        }
        // Unreachable in practice. Falling back to a timestamp keeps the app writing rather than
        // refusing to file a stroke it already has.
        return String(String(Int(Date().timeIntervalSince1970), radix: 16).suffix(idLength))
    }

    public static func isID(_ s: String) -> Bool {
        s.count == idLength && s.allSatisfy { alphabet.contains($0) }
    }

    // MARK: - Surface identity in a file name

    /// `/` is the one character a surface identity may hold that a directory name may not.
    static func flatten(_ surface: String) -> String {
        surface.replacingOccurrences(of: "/", with: "-")
    }

    /// Only the pen's form is recognised. Another client's surface identity round-trips as
    /// whatever it flattened to, which is enough to name a folder; `book.json` is the authority.
    static func unflatten(_ flat: String) -> String {
        let parts = flat.split(separator: "-").map(String.init)
        guard parts.count == 3, parts[0].hasPrefix("s"), parts[1].hasPrefix("o"),
              parts[2].hasPrefix("b") else { return flat }
        return parts.joined(separator: "/")
    }
}

/// One page inside one copy. The unit everything downstream of capture deals in.
///
/// `PageID` alone is not enough to find a file: it names a page of a *product*, and two copies of
/// that product each have one. A pending page, a quiet page and a page in a commit are all this.
public struct PageRef: Hashable, CustomStringConvertible {
    public let folder: BookFolder
    public let page: PageID

    public init(folder: BookFolder, page: PageID) {
        self.folder = folder
        self.page = page
    }

    /// The page number the client used, which is what names the captured file.
    public var number: Int { page.page }

    public var rawRelativePath: String { folder.rawPath(page: number) }

    public var description: String { "\(folder.name)/p\(page.page)" }

    /// Inverse of `rawRelativePath`; nil for anything that is not a captured page file.
    public init?(rawRelativePath: String) {
        let parts = rawRelativePath.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "books", parts[2] == "raw",
              let folder = BookFolder(name: parts[1]),
              parts[3].hasPrefix("p"), parts[3].hasSuffix(".jsonl"),
              let page = Int(parts[3].dropFirst().dropLast(6)),
              let id = PageID(surface: folder.surface, page: page) else { return nil }
        self.init(folder: folder, page: id)
    }
}
