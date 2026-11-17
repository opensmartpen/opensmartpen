import Foundation

/// Minimal timestamped logger to stderr. The app is a background utility; the log is for debugging.
///
/// A warning or an error also goes to `Telemetry`, which sends it to the makers of the app when
/// the person allows that. So a line at those two levels must not carry a name a person gave to
/// something, a file name or a title. A line that must carry one says `telemetry: false`.
public enum Log {
    public static var verbose = false
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func info(_ message: @autoclosure () -> String) {
        write("INFO", message())
    }

    public static func warn(_ message: @autoclosure () -> String, telemetry: Bool = true) {
        let text = message()
        write("WARN", text)
        if telemetry { Telemetry.problem(.warn, text) }
    }

    public static func error(_ message: @autoclosure () -> String, telemetry: Bool = true) {
        let text = message()
        write("ERROR", text)
        if telemetry { Telemetry.problem(.error, text) }
    }

    public static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        write("DEBUG", message())
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(fmt.string(from: Date())) \(level) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
