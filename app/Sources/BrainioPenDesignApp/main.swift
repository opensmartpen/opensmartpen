import AppKit
import BrainioPenDesign

// A separate app from `brainio-pen` on purpose: no pen, no notes repo, no menubar item. That is
// what lets it run beside the installed LaunchAgent without two processes writing to the same
// repo — and what keeps every fixture out of the app people install.
let app = NSApplication.shared
let delegate = DesignAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
