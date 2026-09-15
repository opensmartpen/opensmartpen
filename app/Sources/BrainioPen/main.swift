import AppKit

// One errand that is not the menubar app: proving the connection to DAM. It runs and exits, so it
// can be used on a Mac where the app is already running.
if CommandLine.arguments.contains("--check-dam") { DamCheck.run() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menubar-only: no Dock icon, no main window.
app.setActivationPolicy(.accessory)
app.run()
