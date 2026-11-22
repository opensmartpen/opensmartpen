import Foundation

/// Copies captured files to the bucket, and remembers which ones it has copied.
///
/// One direction only. Nothing is ever read back from the bucket, and nothing in it is deleted
/// by a sync: the notes folder on this Mac is the original, and the bucket is where the rest of
/// the world picks the pages up.
///
/// A captured page goes up as two files — the strokes, then the PNG that `PagePictures` keeps
/// beside them — so that whatever reads the bucket can look at a page without knowing how to draw
/// one. The PNG arrives after its strokes, and `last-modified.txt` after every PNG of the batch,
/// so that one small file is the one to listen for.
///
/// With no bucket connected this does nothing and says everything went well. That is deliberate:
/// the app is whole without a bucket, and the day one is connected every file already on disk is
/// found to be unsent and goes up.
public final class S3Sync: Publishing {
    public let root: URL
    private let ledgerURL: URL
    private let lock = NSLock()
    private var client: S3Client?
    private var sent: [String: Stamp] = [:]

    /// What a file looked like when it was uploaded. A file that still looks like this has
    /// nothing new in it; captured files are only ever appended to, so size alone would nearly
    /// do, and the date is there for the files a person edits by hand.
    struct Stamp: Codable, Equatable {
        let size: Int
        let modified: Double
    }

    private struct Ledger: Codable {
        var destination: String
        var files: [String: Stamp]
    }

    /// `ledger` is the list of what has been uploaded. It lives beside the config rather than
    /// among the notes: it is a fact about this Mac and one bucket, not about the notes.
    public init(root: URL, ledger: URL) {
        self.root = root
        ledgerURL = ledger
    }

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return client != nil
    }

    /// The bucket in use, for the one thing that reads from it.
    public var connection: S3Client? {
        lock.lock(); defer { lock.unlock() }
        return client
    }

    /// Point at a bucket, or at none. A different bucket has received nothing, whatever the list
    /// says about the last one, so the list is only kept when the destination is the same.
    public func connect(_ client: S3Client?) {
        lock.lock(); defer { lock.unlock() }
        self.client = client
        sent = [:]
        guard let client,
              let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data),
              ledger.destination == client.account.destination else { return }
        sent = ledger.files
    }

    /// Upload each of these files that has changed since it was last sent. Stops at the first
    /// failure; what went up before it stays recorded, so a retry sends only the rest.
    public func publish(paths: [String]) throws -> Int {
        lock.lock()
        let client = self.client
        lock.unlock()
        guard let client else { return 0 }

        var uploaded = 0
        defer { if uploaded > 0 { save(for: client) } }
        return try Telemetry.span("s3.upload") { span in
            defer { span.set("s3.files", .int(uploaded)) }
            var seen = Set<String>()
            for path in paths where seen.insert(path).inserted {
                let url = root.appendingPathComponent(path)
                // Read the stamp first. If the pen writes between the two reads, the stamp is the
                // older one and the file is simply found changed, and sent again, next time.
                guard let stamp = Self.stamp(of: url), let data = try? Data(contentsOf: url) else { continue }
                guard recorded(path) != stamp else { continue }

                try put(path, data: data, contentType: Self.contentType(of: path), with: client)
                uploaded += 1
                if let page = PageRef(rawRelativePath: path) {
                    let image = PagePictures.imagePath(for: page)
                    if let png = try? Data(contentsOf: root.appendingPathComponent(image)) {
                        try put(image, data: png, contentType: "image/png", with: client)
                        uploaded += 1
                    }
                }
                // Only now: a page whose picture did not arrive has not arrived.
                record(path, stamp)
            }
            return uploaded
        }
    }

    /// One file to the bucket, timed. Telemetry gets what kind of file it was and how big, and
    /// not its name.
    private func put(_ path: String, data: Data, contentType: String, with client: S3Client) throws {
        let kind = Self.kind(of: path)
        try Telemetry.span("s3.put", ["file.kind": .string(kind), "file.size": .int(data.count)]) { _ in
            try client.put(path, data: data, contentType: contentType)
        }
        Telemetry.count(.filesUploaded, ["file.kind": .string(kind)])
        Telemetry.count(.bytesUploaded, ["file.kind": .string(kind)], by: data.count)
    }

    /// What a file is, by where it is: the strokes of a page, its picture, a record.
    static func kind(of path: String) -> String {
        if path == PagePictures.timePath { return "time" }
        if path == ModeLog.relativePath { return "mode" }
        if path == Palette.relativePath { return "palette" }
        if path.hasPrefix("pens/") { return "pen" }
        if path.hasSuffix("/book.json") { return "book" }
        if path.contains("/pages/") { return "picture" }
        if path.contains("/raw/") { return path.hasSuffix(".jsonl") ? "strokes" : "photo" }
        return "other"
    }

    /// Files under these paths that are on disk but not, as they now stand, in the bucket.
    public func dirtyPaths(under prefixes: [String]) -> [String] {
        guard isConnected else { return [] }
        var out: [String] = []
        for prefix in prefixes {
            for path in Self.files(under: prefix, in: root) {
                guard let stamp = Self.stamp(of: root.appendingPathComponent(path)) else { continue }
                if recorded(path) != stamp { out.append(path) }
            }
        }
        return out
    }

    /// Delete these files from the bucket, by name: a notebook that a person deleted. With no
    /// bucket connected it does nothing. In each case, also when the bucket refuses part of the
    /// way, the files leave the list of what was uploaded, so what stays on disk goes up again.
    public func delete(_ paths: [String]) throws {
        guard let client = connection else { return }
        defer { forget(paths) }
        for path in paths { try client.delete(path) }
    }

    /// Drop these files from the list of what was uploaded: they were deleted from the bucket,
    /// or may have been. A file that is still on disk then goes up again at the next sync.
    public func forget(_ paths: [String]) {
        lock.lock()
        for path in paths { sent[path] = nil }
        let client = self.client
        lock.unlock()
        if let client { save(for: client) }
    }

    // MARK: - pieces

    private func recorded(_ path: String) -> Stamp? {
        lock.lock(); defer { lock.unlock() }
        return sent[path]
    }

    private func record(_ path: String, _ stamp: Stamp) {
        lock.lock(); defer { lock.unlock() }
        sent[path] = stamp
    }

    private func save(for client: S3Client) {
        lock.lock()
        // The bucket may have been changed while these were going up. Then the list in memory is
        // already the new bucket's, and this batch is not part of it.
        guard self.client === client else { lock.unlock(); return }
        let ledger = Ledger(destination: client.account.destination, files: sent)
        lock.unlock()
        do {
            try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(ledger).write(to: ledgerURL, options: .atomic)
        } catch {
            // Not fatal: the worst that follows is a file uploaded twice.
            Log.warn("could not record what was uploaded: \(error)")
        }
    }

    static func stamp(of url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Stamp(size: size.intValue, modified: modified.timeIntervalSince1970)
    }

    /// Every file at or under a path relative to the notes folder. Hidden files are skipped: a
    /// `.DS_Store` is the Finder's business, not the bucket's.
    static func files(under prefix: String, in root: URL) -> [String] {
        let fm = FileManager.default
        let trimmed = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        let start = root.appendingPathComponent(trimmed)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: start.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [trimmed] }
        guard let walk = fm.enumerator(atPath: start.path) else { return [] }
        var out: [String] = []
        for case let name as String in walk {
            guard !name.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            out.append("\(trimmed)/\(name)")
        }
        return out.sorted()
    }

    static func contentType(of path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "jsonl": return "application/x-ndjson"
        case "json": return "application/json"
        case "png": return "image/png"
        case "txt": return "text/plain; charset=utf-8"
        case "md": return "text/markdown; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
