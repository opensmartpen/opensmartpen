import Foundation

/// Adds lines to a file that is only ever added to. Every raw file is written through this.
///
/// The one thing it does beyond writing is close a broken last line. A process that dies in
/// mid-write leaves a file whose last line has no newline; writing the next record straight onto
/// the end would join the two into one line that parses as neither, so a single interruption would
/// cost the record it was writing *and* the next one. ADR-001 promises that a stopped capture
/// costs only the line it was on, so the missing newline is put back before anything else is
/// written. The broken line stays where it is: it is evidence, and the record is never rewritten.
enum AppendOnlyFile {
    static let newline = Data("\n".utf8)

    static func append(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(text.utf8)
        guard fm.fileExists(atPath: url.path) else {
            try data.write(to: url, options: .atomic)
            return
        }
        // Opened for updating, not writing: the last byte has to be read before it can be judged,
        // and a write-only handle cannot be read from.
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != newline {
                try handle.write(contentsOf: newline)
            }
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}
