import AppKit
import OpenSmartPenCore
import OpenSmartPenUI
import SwiftUI

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

    /// `--render=<state>:<file.png>` writes the dark panel of one state as a picture, at twice
    /// its size and with nothing behind it, and opens no window. A picture of the screen has the
    /// screen's own resolution and whatever is behind the panel; this has neither. It is how
    /// `assets/panel.png` gets its panel.
    @MainActor
    private static func render(_ what: String) {
        let parts = what.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let scenario = Scenario(rawValue: parts[0]) else {
            FileHandle.standardError.write(Data("usage: --render=<state>:<file.png>\n".utf8))
            return
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let model = PanelModel(snapshot: scenario.snapshot)
        let renderer = ImageRenderer(content: StatusPanel(model: model, now: Date())
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("the panel could not be drawn\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: (parts[1] as NSString).expandingTildeInPath))
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let flag = arguments.first(where: { $0.hasPrefix("--render=") }) {
            Self.render(String(flag.dropFirst("--render=".count)))
            NSApp.terminate(nil)
            return
        }
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
        } else if let flag = arguments.first(where: { $0.hasPrefix("--samples") }) {
            // `--samples=setup` shows the window as a person with no agent sees it.
            let setup = flag.hasSuffix("=setup")
                ? "Read https://opensmartpen.org/llms.txt and set yourself up to transcribe my Open Smart Pen pages. The pages are in the folder ~/OpenSmartPen on my Mac."
                : nil
            controller = SampleGalleryController(setup: setup, first: setup != nil) { _, _ in NSApp.terminate(nil) }
        } else if arguments.contains("--notice") {
            // The design app has no icon of its own. The window shows the app's icon, so it is
            // given the one the build draws, when a build has drawn it.
            if let icon = NSImage(contentsOfFile: FileManager.default.currentDirectoryPath + "/Resources/AppIcon.icns") {
                NSApp.applicationIconImage = icon
            }
            let notice = TelemetryNoticeController(installId: "3f2a9c1e-7b4d-4e6a-9c0d-5a1b2c3d4e5f", encrypted: true, ours: true)
            notice.onAnswer = { _, _ in NSApp.terminate(nil) }
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
        // The same for the updater: only a release has one, and its rows must be looked at.
        info.updates = UpdateControls(check: {}, isAutomatic: { true }, setAutomatic: { _ in })
        let store = SettingsStore(pens: pens, books: books, config: config,
                                  configURL: info.configURL, info: info, secretURL: secret)
        if bucket {
            store.sync.lastUpload = Date().addingTimeInterval(-140)
            store.sync.lastFiles = 4
        }
        return store
    }
}
