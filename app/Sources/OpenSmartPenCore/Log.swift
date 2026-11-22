import Foundation

/// Minimal timestamped logger. The app is a background utility; the log is for debugging.
///
/// A line goes to the file given with `keep(in:)`, which has a limit to its size. It goes to
/// stderr too when that is a terminal, or when there is no file, as in the tests and the tools.
///
/// A warning or an error also goes to `Telemetry`, which sends it to the makers of the app when
/// the person allows that. So a line at those two levels must not carry a name a person gave to
/// something, a file name or a title. A line that must carry one says `telemetry: false`.
/// The line goes with the place in the source that wrote it (`file`, `line`), which is how a
/// maker finds the code behind a message that has changed its words since.
public enum Log {
    public static var verbose = false
    private static var file: LogFile?
    private static let toTerminal = isatty(STDERR_FILENO) == 1

    /// Keep the log in this file from now on. Called one time, when the app starts.
    public static func keep(in url: URL) { file = LogFile(url: url) }

    /// Where the app keeps its log: the place macOS has for the logs of one person.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/OpenSmartPen/opensmartpen.log")
    }
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func info(_ message: @autoclosure () -> String) {
        write("INFO", message())
    }

    public static func warn(_ message: @autoclosure () -> String, telemetry: Bool = true,
                            file: String = #fileID, line: Int = #line) {
        let text = message()
        write("WARN", text)
        // A line whose words stay on this Mac is still counted: that it happened names nobody.
        if telemetry { Telemetry.problem(.warn, text, file: file, line: line) }
        else { Telemetry.count(.problems, ["log.level": "warn"]) }
    }

    /// `sent` is the line for telemetry when the line for the log holds words that stay here.
    public static func error(_ message: @autoclosure () -> String, telemetry: Bool = true,
                             sent: @autoclosure () -> String? = nil,
                             file: String = #fileID, line: Int = #line) {
        let text = message()
        write("ERROR", text)
        if telemetry { Telemetry.problem(.error, sent() ?? text, file: file, line: line) }
        else { Telemetry.count(.problems, ["log.level": "error"]) }
    }

    public static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        write("DEBUG", message())
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(fmt.string(from: Date())) \(level) \(message)\n"
        let data = Data(line.utf8)
        file?.append(data)
        if file == nil || toTerminal { FileHandle.standardError.write(data) }
    }
}
