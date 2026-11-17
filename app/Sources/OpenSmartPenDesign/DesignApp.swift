import AppKit
import OpenSmartPenCore
import OpenSmartPenUI

/// The design app is one window and nothing else. It opens on launch and quits when the window
/// closes, because there is nothing left for it to do.
///
/// Usually that window is the panel in every state. With `--settings` it is the settings window
/// instead, on fixtures in a temporary folder: `--settings=sync` opens it on a tab, and adding
/// `--bucket` shows it as it is once a bucket is connected. With `--viewer=<notes>:<copy>:<page>`
/// it is the viewer, on a real page, reading only. With `--notice` it is the window that tells a
/// person about telemetry.
public final class DesignAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindowController?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let controller: NSWindowController
        if let flag = arguments.first(where: { $0.hasPrefix("--settings") }) {
            let named = flag.split(separator: "=").dropFirst().first.map(String.init)
            let tab = SettingsTab.allCases.first { "\($0)" == named } ?? .pens
            controller = SettingsWindowController(store: Self.settings(bucket: arguments.contains("--bucket")),
                                                  tab: tab)
            controller.window?.delegate = self
        } else if let flag = arguments.first(where: { $0.hasPrefix("--viewer=") }) {
            // `--viewer=<notes folder>:<copy>:<page>` opens the viewer on a real page, reading
            // only. The transcript shown is whatever is already kept under that folder: there
            // is no bucket here to ask.
            let parts = flag.dropFirst("--viewer=".count).split(separator: ":").map(String.init)
            let root = URL(fileURLWithPath: ((parts.first ?? "") as NSString).expandingTildeInPath)
            let books = BookRegistry(root: root)
            // Before the viewer exists: it reads this once, when it is made.
            UserDefaults.standard.set(true, forKey: "viewer.transcript")
            let viewer = Viewer(books: books, repo: root)
            viewer.transcripts = TranscriptStore(root: root) { nil }
            if parts.count == 3, let folder = BookFolder(name: parts[1]), let number = Int(parts[2]),
               let id = PageID(surface: folder.surface, page: number) {
                viewer.show(page: PageRef(folder: folder, page: id))
            } else {
                viewer.goLatest()
            }
            controller = ViewerWindowController(viewer: viewer)
            controller.window?.delegate = self
        } else if arguments.contains("--notice") {
            let notice = TelemetryNoticeController(installId: "3f2a9c1e-7b4d-4e6a-9c0d-5a1b2c3d4e5f")
            notice.onAnswer = { _ in NSApp.terminate(nil) }
            controller = notice
        } else {
            controller = DesignWindowController()
        }
        window = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    /// A settings store with three pens and two notebooks behind it, none of them real. Everything
    /// it writes goes to a folder that is thrown away, including the secret.
    private static func settings(bucket: Bool) -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensmartpen-design-\(ProcessInfo.processInfo.processIdentifier)")
        let notes = root.appendingPathComponent("notes")
        try? FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try? Data(##"{"ink":{"black":"#000000","red":"#ff0200","blue":"#00abeb","green":"#3cdd00","yellow":"#ffd400"}}"##.utf8)
            .write(to: notes.appendingPathComponent(Palette.relativePath))

        let pens = PenRegistry(repo: notes)
        pens.create(mac: "9c7bd2000001", name: "Everyday")
        if var marker = pens.create(mac: "9c7bd2000003", name: "Marker") {
            marker.mode = .highlight
            marker.ink = .yellow
            marker.width = .thick
            pens.save(marker)
        }
        if var red = pens.create(mac: "9c7bd2000002", name: "Red one") {
            red.ink = .red
            red.width = .thin
            pens.save(red)
        }
        let books = BookRegistry(root: notes)
        books.ensureRecord(for: PageID(section: 3, owner: 1012, book: 3017, page: 6))
        books.ensureRecord(for: PageID(section: 3, owner: 27, book: 450, page: 3))

        var config = Config()
        config.dataPath = notes.path
        let secret = root.appendingPathComponent("s3-secret")
        if bucket {
            config.s3.bucket = "my-notes"
            config.s3.region = "eu-central-1"
            config.s3.accessKeyId = "AKIAIOSFODNN7EXAMPLE"
            config.s3.prefix = "pen"
            try? S3Secret.write("not-a-real-secret", to: secret)
        }
        var info = AppInfo(version: "0.0.0", sdk: "NISDK3 1.1.5",
                           configURL: root.appendingPathComponent("config.json"),
                           logURL: root.appendingPathComponent("opensmartpen.log"))
        info.installId = "3f2a9c1e-7b4d-4e6a-9c0d-5a1b2c3d4e5f"
        // The design window is a bare binary and carries no license texts. A packaged app does,
        // and that is the state worth looking at, so the fixture stands in for the folder.
        info.licensesURL = root
        let store = SettingsStore(pens: pens, books: books, config: config,
                                  configURL: info.configURL, info: info, secretURL: secret)
        if bucket {
            store.sync.lastUpload = Date().addingTimeInterval(-140)
            store.sync.lastFiles = 4
        }
        return store
    }
}
