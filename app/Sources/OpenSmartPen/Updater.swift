import AppKit
import OpenSmartPenCore
import OpenSmartPenUI
import Sparkle

/// Updates of a packaged release, by Sparkle.
///
/// Only a release has a feed: `scripts/package.sh` writes `SUFeedURL` and the public key into the
/// bundle, and `scripts/make-app.sh` on its own does not. So a development build has no updater,
/// and cannot replace itself with the last release while somebody is working on it.
///
/// An update is quiet. Sparkle downloads it with no window, and then hands the install to this
/// class, which waits for a moment that nobody notices (`UpdateMoment`) and restarts the app. A
/// person sees a window only when they ask: "Check for Updates…" in the About tab.
///
/// The check is one request for a public file. Nothing about this Mac or its notes goes with it.
final class Updater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    /// Sparkle's own "install now and start again", kept until the moment is quiet.
    private var install: (() -> Void)?
    /// The version that is downloaded and waits, for the log.
    private var waiting: String?

    /// Nil when this build has no feed.
    init?(hasFeed: Bool = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil) {
        guard hasFeed else { return nil }
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self,
                                                  userDriverDelegate: nil)
    }

    /// What the About tab needs, in the UI layer's own words: that layer does not know Sparkle.
    var controls: UpdateControls {
        UpdateControls(
            check: { [controller] in
                // A menubar app is not the active app, and its window would open behind the others.
                NSApp.activate(ignoringOtherApps: true)
                controller?.checkForUpdates(nil)
            },
            isAutomatic: { [controller] in controller?.updater.automaticallyChecksForUpdates ?? false },
            // One switch for both halves. A check that finds an update and does not download it
            // shows a window, and a window is what this app does not do unasked.
            setAutomatic: { [controller] on in
                controller?.updater.automaticallyChecksForUpdates = on
                controller?.updater.automaticallyDownloadsUpdates = on
            }
        )
    }

    /// True when an update is downloaded and waits for a quiet moment.
    var isWaiting: Bool { install != nil }

    /// Install the update that waits, and start the app again. Call it only at a quiet moment,
    /// after the pens are let go. Does nothing when no update waits.
    func installNow() {
        guard let install else { return }
        Log.info("installing update \(waiting ?? "?") and starting again")
        install()
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle has the update on disk and would install it when the app quits. A menubar app does
    /// not quit for weeks, so the install is taken over here and done at a quiet moment.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        install = immediateInstallHandler
        waiting = item.displayVersionString
        Log.info("update \(item.displayVersionString) is downloaded; it installs at the next quiet moment")
        return true
    }
}
