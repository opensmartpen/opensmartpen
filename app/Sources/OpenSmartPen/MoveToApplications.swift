import AppKit
import OpenSmartPenCore

/// Offers, at the start, to put the app in the Applications folder when it runs from the disk
/// image or from Downloads. See `AppLocation` for why.
enum MoveToApplications {
    private static let declinedKey = "move.declined"

    /// Returns true when the app was moved and a new copy is starting: the caller must do
    /// nothing more, because this copy is about to quit.
    @MainActor
    static func offerIfNeeded() -> Bool {
        let bundle = Bundle.main.bundleURL
        let location = AppLocation(bundle: bundle)
        guard location.offersMove else { return false }
        // A "not now" is remembered for a place the app can stay in. From the disk image it is
        // asked each time: the app there cannot update itself, and is gone when the image is.
        if !location.cannotStay, UserDefaults.standard.bool(forKey: declinedKey) { return false }

        let name = "Open Smart Pen.app"
        let destination = AppMover.destination(name: name)
        let alert = NSAlert()
        alert.messageText = "Move Open Smart Pen to the Applications folder?"
        alert.informativeText = (location == .downloads
            ? "It is running from the Downloads folder. "
            : "It is running from the disk image. ")
            + "In the Applications folder it can update itself, and it is still there after the disk image is gone."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: declinedKey)
            Log.info("the move to the Applications folder was declined")
            return false
        }

        do {
            quitOtherCopies()
            try AppMover.install(from: bundle, to: destination)
            // The copy keeps the mark of a downloaded file. macOS would then run it from a hidden
            // read-only place again, which is what the move is there to end. The person asked for
            // this app to be put here, and the download was checked when it was first opened.
            run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
            Log.info("moved to \(destination.deletingLastPathComponent().path); starting the copy there")
            // Started a moment later, by a process of its own, so this copy is gone first: two
            // copies would both take the pen.
            let start = Process()
            start.executableURL = URL(fileURLWithPath: "/bin/sh")
            start.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", destination.path]
            try start.run()
            NSApp.terminate(nil)
            return true
        } catch {
            Log.warn("could not move to the Applications folder: \(error.localizedDescription)")
            let failed = NSAlert()
            failed.messageText = "Open Smart Pen could not be moved"
            failed.informativeText = "\(error.localizedDescription)\n\nDrag it to the Applications folder by hand. The app continues from where it is."
            failed.runModal()
            return false
        }
    }

    /// An older copy that is running from the Applications folder must stop before it is
    /// replaced, and before the new one starts.
    private static func quitOtherCopies() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, others.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }
}
