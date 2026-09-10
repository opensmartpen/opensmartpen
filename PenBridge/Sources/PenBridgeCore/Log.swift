import Foundation

/// Minimal timestamped logger to stderr. The app is a background utility; the log is for debugging.
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

    public static func warn(_ message: @autoclosure () -> String) {
        write("WARN", message())
    }

    public static func error(_ message: @autoclosure () -> String) {
        write("ERROR", message())
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
