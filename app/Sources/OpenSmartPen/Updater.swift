import AppKit
import OpenSmartPenUI
import Sparkle

/// Updates of a packaged release, by Sparkle.
///
/// Only a release has a feed: `scripts/package.sh` writes `SUFeedURL` and the public key into the
/// bundle, and `scripts/make-app.sh` on its own does not. So a development build has no updater,
/// and cannot replace itself with the last release while somebody is working on it.
///
/// The check is one request for a public file. Nothing about this Mac or its notes goes with it.
final class Updater {
    private let controller: SPUStandardUpdaterController

    /// Nil when this build has no feed.
    init?() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    /// What the About tab needs, in the UI layer's own words: that layer does not know Sparkle.
    var controls: UpdateControls {
        UpdateControls(
            check: { [controller] in
                // A menubar app is not the active app, and its window would open behind the others.
                NSApp.activate(ignoringOtherApps: true)
                controller.checkForUpdates(nil)
            },
            isAutomatic: { [controller] in controller.updater.automaticallyChecksForUpdates },
            setAutomatic: { [controller] on in controller.updater.automaticallyChecksForUpdates = on }
        )
    }
}
