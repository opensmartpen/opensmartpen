import Foundation

/// One crash of the app, as macOS wrote it down.
///
/// macOS writes a report for every process that crashes, in `~/Library/Logs/DiagnosticReports`.
/// The app reads its own at the next start. Nothing has to run at the moment of the crash, which
/// is the moment when nothing can be trusted to run.
public struct CrashReport: Equatable {
    public var incident: String
    public var time: Date
    public var appVersion: String
    public var osVersion: String
    /// `EXC_BREAKPOINT (SIGTRAP)`.
    public var kind: String
    /// What macOS and the Swift runtime said about it: "Trace/BPT trap: 5", "Fatal error: …".
    public var message: String
    /// The thread that crashed, one frame to a line, innermost first.
    public var stack: String
    /// Which build of the binary this was, so the addresses in the stack can be given names.
    public var binaryUUID: String

    /// The most frames kept. What matters is at the top.
    static let frameLimit = 60

    /// Read a `.ips` file: one line of JSON that says what the report is, then the report, also
    /// JSON. Nil for a file that is not a crash of `process`.
    public static func parse(_ data: Data, process: String) -> CrashReport? {
        let text = String(decoding: data, as: UTF8.self)
        guard let newline = text.firstIndex(of: "\n"),
              let head = object(String(text[..<newline])),
              let body = object(String(text[text.index(after: newline)...])),
              (head["app_name"] as? String ?? body["procName"] as? String) == process,
              let exception = body["exception"] as? [String: Any] else { return nil }

        let stamp = head["timestamp"] as? String ?? body["captureTime"] as? String ?? ""
        let type = exception["type"] as? String ?? "crash"
        let signal = exception["signal"] as? String
        var words: [String] = []
        if let said = (body["termination"] as? [String: Any])?["indicator"] as? String { words.append(said) }
        // What the process itself said as it went down: the text of a `fatalError`.
        for (_, lines) in (body["asi"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            words.append(contentsOf: lines as? [String] ?? [])
        }

        let images = body["usedImages"] as? [[String: Any]] ?? []
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int ?? threads.firstIndex { $0["triggered"] as? Bool == true } ?? 0
        let frames = threads.indices.contains(faulting) ? threads[faulting]["frames"] as? [[String: Any]] ?? [] : []
        let lines = frames.prefix(frameLimit).enumerated().map { index, frame -> String in
            let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil }
            // The name of the binary, never its path: the path has the account name in it.
            let name = image?["name"] as? String ?? "?"
            let offset = frame["imageOffset"] as? Int ?? 0
            if let symbol = frame["symbol"] as? String {
                return "\(index) \(name) \(symbol) + \(frame["symbolLocation"] as? Int ?? 0)"
            }
            return "\(index) \(name) 0x\(String(offset, radix: 16))"
        }
        let binary = images.first { $0["name"] as? String == process }?["uuid"] as? String
            ?? head["slice_uuid"] as? String ?? ""

        return CrashReport(incident: head["incident_id"] as? String ?? body["incident"] as? String ?? "",
                           time: date(stamp) ?? Date(),
                           appVersion: head["app_version"] as? String ?? "",
                           osVersion: head["os_version"] as? String ?? "",
                           kind: signal.map { "\(type) (\($0))" } ?? type,
                           message: words.joined(separator: "\n"),
                           stack: lines.joined(separator: "\n"),
                           binaryUUID: binary)
    }

    /// The reports of `process` in a folder that were written after `after`, oldest first, and
    /// not more than `limit` of them: an app that crashes at every start must not send a flood.
    public static func recent(in directory: URL, process: String, after: Date, limit: Int = 5) -> [CrashReport] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        var found: [CrashReport] = []
        for name in names where name.hasPrefix("\(process)-") && name.hasSuffix(".ips") {
            let url = directory.appendingPathComponent(name)
            guard let written = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  written > after, let data = try? Data(contentsOf: url),
                  let report = parse(data, process: process) else { continue }
            found.append(report)
        }
        return Array(found.sorted { $0.time < $1.time }.suffix(limit))
    }

    /// Where macOS keeps the reports of this person's processes.
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    private static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// `2026-11-12 14:30:39.00 +0100`, with any number of digits after the seconds.
    static func date(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count == 3 else { return nil }
        let seconds = parts[1].split(separator: ".").first.map(String.init) ?? String(parts[1])
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return format.date(from: "\(parts[0]) \(seconds) \(parts[2])")
    }
}
