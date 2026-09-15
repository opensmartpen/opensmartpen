import Foundation

/// The DAM API key, in a file of its own beside the config.
///
/// It was in the Keychain until 2026-09-15, and the Keychain did not earn its place. Its protection
/// is an access list bound to the app's code signature, and this app is signed ad hoc — so every
/// rebuild is a different app to macOS, which asks again, in a dialog that blocks the caller until
/// somebody answers it. One of those froze the app on launch, and an unanswered one turned reading
/// off for a night. The app is not sandboxed, so a file this process can read is a file any process
/// running as this person can read; the Keychain was buying very little for that.
///
/// A file of its own, rather than a field in `config.json`: the config is a plain file a person
/// opens, edits and pastes into a bug report, and a bearer token should not travel that way.
public enum DamKey {
    public static var location: URL {
        Config.defaultLocation.deletingLastPathComponent().appendingPathComponent("dam-key")
    }

    /// The key, or nil when there is no file or it holds nothing.
    public static func read(at url: URL = location) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        warnIfReadableByOthers(url)
        return key
    }

    /// Store the key, or delete the file when `value` is nil or empty.
    ///
    /// Written 0600 and atomically, and the mode is set on the file that ends up in place — a
    /// replace can otherwise leave the temporary file's own permissions behind.
    public static func write(_ value: String?, to url: URL = location) throws {
        let key = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data((key + "\n").utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Said once a launch, not fixed silently: a person who has loosened the file's permissions on
    /// purpose should not have the app quietly undo it, and one who has not should be told.
    private static func warnIfReadableByOthers(_ url: URL) {
        guard let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
        else { return }
        if mode.int16Value & 0o077 != 0 {
            Log.warn("\(url.path) can be read by other users of this Mac. Fix with: chmod 600 \(url.path)")
        }
    }
}
