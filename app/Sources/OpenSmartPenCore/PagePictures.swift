import Foundation

/// Makes the picture of a page. The drawing needs Core Graphics, which this layer does not have,
/// so it arrives from above.
public protocol PageImaging: AnyObject {
    func png(for ref: PageRef) -> Data?
}

/// Keeps a picture of each page in the notes folder, beside its strokes, and then passes the
/// page on to wherever it is sent next.
///
/// The picture is what an agent looks at: something that transcribes a page should not have to
/// know how to draw one. It is written at `books/<copy>/pages/p<N>.png` when the pen has gone
/// quiet, with or without a bucket, so the folder on this Mac and the bucket have one layout and
/// one contract (`docs/processing.md`). The strokes are on disk before the picture is, so the
/// picture is the file to listen for in the folder, as it is in the bucket.
public final class PagePictures: Publishing {
    public let root: URL
    private let next: Publishing
    public var imaging: PageImaging?
    /// Paper that is tapped, not written on. It gets no picture, so it is never short of one.
    public var controlBooks: Set<String> = []

    public init(root: URL, next: Publishing) {
        self.root = root
        self.next = next
    }

    /// The one file that says the pages changed: `last-modified.txt`, at the top of the folder.
    /// An agent reads this file alone to learn whether there is anything to look at.
    public static let timePath = "last-modified.txt"
    /// The version of the rules an agent was given. Raised only when the layout, the order or
    /// the meaning of a file changes, so an agent knows its instructions are out of date.
    public static let rulesVersion = 1
    /// The clock, so a test can hold it.
    public var now: () -> Date = Date.init

    /// Draw each of these pages, then send the files on. A page is drawn every time it is
    /// published, because it is published when it has been written on. The file is only replaced
    /// when the picture is different, so a retry does not wake an agent for nothing.
    ///
    /// When a picture did change, the time file is written after the last of them, and it is the
    /// last file sent on: whoever sees it change finds every page already there.
    public func publish(paths: [String]) throws -> Int {
        var seen = Set<String>()
        var changed = false
        for path in paths where seen.insert(path).inserted {
            guard let page = PageRef(rawRelativePath: path), let png = image(of: page) else { continue }
            let url = root.appendingPathComponent(Self.imagePath(for: page))
            if (try? Data(contentsOf: url)) == png { continue }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            changed = true
        }
        let time = root.appendingPathComponent(Self.timePath)
        if changed { try Self.timeFile(at: now()).write(to: time, options: .atomic) }
        let exists = FileManager.default.fileExists(atPath: time.path)
        return try next.publish(paths: exists ? paths + [Self.timePath] : paths)
    }

    /// Two lines: when a page picture last changed, and the version of the rules. The time is
    /// compared with the one seen last, never with a clock, so it has milliseconds: two changes
    /// in one second are still two different values.
    static func timeFile(at date: Date) -> Data {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Data("changed: \(format.string(from: date))\nrules: \(rulesVersion)\n".utf8)
    }

    /// What has not been sent, and also every page whose picture is missing or older than its
    /// strokes: a page written just before the app stopped, or captured by a build that kept no
    /// pictures.
    public func dirtyPaths(under prefixes: [String]) -> [String] {
        var out = next.dirtyPaths(under: prefixes)
        var seen = Set(out)
        for prefix in prefixes {
            for path in S3Sync.files(under: prefix, in: root) {
                guard let page = PageRef(rawRelativePath: path),
                      !controlBooks.contains(page.folder.surface),
                      isStale(page), seen.insert(path).inserted else { continue }
                out.append(path)
            }
        }
        return out
    }

    /// Where a page's picture is: beside the strokes, under the same name.
    public static func imagePath(for page: PageRef) -> String {
        page.folder.pagePath(stem: "p\(page.number)", ext: "png")
    }

    private func isStale(_ page: PageRef) -> Bool {
        guard let strokes = Self.modified(root.appendingPathComponent(page.rawRelativePath)) else { return false }
        guard let picture = Self.modified(root.appendingPathComponent(Self.imagePath(for: page))) else { return true }
        return picture < strokes
    }

    private static func modified(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    /// The drawing reads the same in-memory ink state the panel does, which belongs to the main
    /// thread. Publishing runs off it, so the drawing is the one step that goes back.
    private func image(of page: PageRef) -> Data? {
        guard let imaging else { return nil }
        if Thread.isMainThread { return imaging.png(for: page) }
        return DispatchQueue.main.sync { imaging.png(for: page) }
    }
}
