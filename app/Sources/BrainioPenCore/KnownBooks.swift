import Foundation

/// Ncode products we recognise on sight, so a new notebook names itself instead of asking.
///
/// A section/owner/book triple identifies a *product*, not a copy — which is what makes the
/// collision problem hard, and also what makes this table possible: every LAMY digital paper
/// notebook in the world reports the same id, so knowing it once is knowing it always.
///
/// The alternative was showing the raw book number, and "Notebook 3017" is a product code leaking
/// into the interface. A person does not know what 3017 means and should not have to.
public enum KnownBooks {
    public struct Product {
        public let title: String
        public let binding: Binding
        public let widthMM: Double
        public let heightMM: Double
        public let firstPage: Int
        public let note: String?
    }

    /// Keyed by `PageID.bookKey`, `s{section}/o{owner}/b{book}`.
    public static let products: [String: Product] = [
        "s3/o27/b450": Product(
            title: "A4 pad", binding: .pad, widthMM: 210, heightMM: 297, firstPage: 1,
            note: "NeoLAB Ncode A4 bundle (NC-P0081E)"),
        "s3/o1012/b3017": Product(
            title: "LAMY notebook", binding: .bound, widthMM: 145, heightMM: 210, firstPage: 1,
            note: "NeoLAB LAMY digital paper, 192 pages, dot ruled (145 x 210 mm)"),
    ]

    /// How the paper is held together, which decides how it is read. A pad is loose sheets, seen
    /// one at a time; a bound notebook falls open at two facing pages and reading one of them
    /// alone is not how anybody uses it.
    ///
    /// Not derivable from the paper size — two notebooks of identical dimensions can be bound or
    /// not — so it is recorded rather than guessed.
    public enum Binding: String, Codable, CaseIterable {
        case pad, bound
    }

    public static func product(forBookKey key: String) -> Product? { products[key] }

    /// What to call a notebook we do not recognise. Named for what it is rather than for its
    /// product code: the paper size is something a person can see, and a book we have never met
    /// still has one as soon as a page arrives.
    public static func fallbackTitle(widthMM: Double?, heightMM: Double?) -> String {
        guard let w = widthMM, let h = heightMM else { return "Notebook" }
        switch (w, h) {
        case let (w, h) where near(w, 210) && near(h, 297): return "A4 pad"
        case let (w, h) where near(w, 297) && near(h, 420): return "A3 pad"
        case let (w, h) where near(w, 148) && near(h, 210): return "A5 notebook"
        case let (w, h) where near(w, 105) && near(h, 148): return "A6 notebook"
        case let (w, h) where near(w, 145) && near(h, 210): return "Notebook"
        case let (w, h) where w > h: return "Landscape pad"
        case let (w, h) where h > w * 1.6: return "Tall notebook"
        default: return "Notebook"
        }
    }

    private static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 8 }

    /// The shape of the paper, for the small mark beside a page in the panel. Proportions we
    /// already store, so the mark means something rather than decorating.
    public enum Shape {
        case wide       // landscape
        case page       // A4-ish upright
        case pocket     // narrow and tall

        public init(widthMM: Double?, heightMM: Double?) {
            guard let w = widthMM, let h = heightMM, w > 0, h > 0 else { self = .page; return }
            let ratio = h / w
            if ratio < 1 { self = .wide }
            else if ratio > 1.5 { self = .pocket }
            else { self = .page }
        }
    }
}
