import Foundation

/// Where the app is running from, as far as it matters for staying there.
///
/// A person opens the disk image and double-clicks the app in it, without dragging it anywhere.
/// The app then runs from the image, or from a hidden read-only copy macOS makes of it. It works,
/// until the image is ejected, and it can never update itself. So the app looks where it is, and
/// offers to put itself in the Applications folder.
public enum AppLocation: Equatable {
    /// In `/Applications` or in the person's own `~/Applications`. Nothing to do.
    case applications
    /// On a mounted disk image.
    case diskImage
    /// In the hidden read-only copy macOS runs a downloaded app from when it was not moved by hand.
    case translocated
    /// In the Downloads folder, unpacked and opened there.
    case downloads
    /// Anywhere else: a place somebody chose. Left alone.
    case elsewhere
    /// Not an app bundle at all: a bare binary, as a developer runs it.
    case notABundle

    public init(bundle: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let path = bundle.standardizedFileURL.path
        guard path.hasSuffix(".app") else { self = .notABundle; return }
        func inside(_ folder: String) -> Bool { path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") }
        if inside("/Applications") || inside(home.appendingPathComponent("Applications").path) {
            self = .applications
        } else if path.contains("/AppTranslocation/") {
            self = .translocated
        } else if inside("/Volumes") {
            self = .diskImage
        } else if inside(home.appendingPathComponent("Downloads").path) {
            self = .downloads
        } else {
            self = .elsewhere
        }
    }

    /// The app cannot stay where it is: the place goes away, or cannot be written to.
    public var cannotStay: Bool { self == .diskImage || self == .translocated }

    /// The move is offered. Not for a place somebody chose on purpose.
    public var offersMove: Bool { cannotStay || self == .downloads }
}

/// Puts the app in the Applications folder.
public enum AppMover {
    /// `/Applications` when this person may write there, else their own `~/Applications`.
    public static func destination(name: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   systemWritable: Bool = FileManager.default.isWritableFile(atPath: "/Applications")) -> URL {
        let folder = systemWritable ? URL(fileURLWithPath: "/Applications") : home.appendingPathComponent("Applications")
        return folder.appendingPathComponent(name)
    }

    /// Copy the app to `destination`. A copy that is there already is put aside first and
    /// removed only when the new one is in place, so a copy that fails leaves the old app.
    public static func install(from source: URL, to destination: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var aside: URL?
        if files.fileExists(atPath: destination.path) {
            let old = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
            try files.moveItem(at: destination, to: old)
            aside = old
        }
        do {
            try files.copyItem(at: source, to: destination)
        } catch {
            if let aside { try? files.moveItem(at: aside, to: destination) }
            throw error
        }
        if let aside { try? files.removeItem(at: aside) }
    }
}
