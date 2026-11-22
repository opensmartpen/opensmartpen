import Foundation

/// The log of the app, as a file that cannot fill the disk.
///
/// The app writes the file itself, so there is a log however the app was started: from the
/// Finder, at login, or by an agent of launchd. When the file is at its limit it becomes
/// `<name>.1.<ext>`, in place of the one that had that name, and a new file starts. So the log
/// is never more than two times the limit.
public final class LogFile {
    public let url: URL
    /// The file that was full last, kept beside the one that is written.
    public let previousURL: URL
    private let limit: Int
    private var handle: FileHandle?
    private var size = 0
    private let lock = NSLock()

    /// `limit` is in bytes. The folder is made when it is not there.
    public init(url: URL, limit: Int = 2_000_000) {
        self.url = url
        self.limit = limit
        let ext = url.pathExtension
        let base = url.deletingPathExtension()
        previousURL = ext.isEmpty ? base.appendingPathExtension("1")
            : base.appendingPathExtension("1").appendingPathExtension(ext)
        open()
    }

    /// Add to the end. A log that cannot be written is not worth stopping the app for, so this
    /// does not throw: it tries to open the file again at the next line.
    public func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if handle == nil { open() }
        if size > 0, size + data.count > limit { rotate() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            size += data.count
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }

    private func open() {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
        guard let opened = try? FileHandle(forWritingTo: url) else { return }
        size = Int((try? opened.seekToEnd()) ?? 0)
        handle = opened
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        try? manager.removeItem(at: previousURL)
        do { try manager.moveItem(at: url, to: previousURL) } catch {
            // The full file could not be put aside. Empty it: the limit is the promise.
            try? manager.removeItem(at: url)
        }
        open()
    }
}
