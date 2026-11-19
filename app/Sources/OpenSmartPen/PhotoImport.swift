import AppKit
import OpenSmartPenCore

/// Takes a picture from an iPhone or iPad near this Mac.
///
/// macOS drives the device itself. It puts "Import from iPhone or iPad" into the context menu of
/// a view that says it takes pictures, with "Take Photo" and "Scan Documents" for every device
/// it can reach, and hands the picture back to that view. So there has to be a view, in a window
/// that has the keyboard focus, and the sheet macOS shows while it waits needs a window to hang
/// from.
///
/// That window is here and cannot be seen: no frame, no colour, one point high, in the middle of
/// the screen. What a person sees is the device menu, opened where they clicked, and then macOS's
/// own "waiting for your iPhone" sheet.
final class PhotoImportController: NSObject {
    /// A picture arrived, with the file extension that says what it is.
    var onImage: ((Data, String) -> Void)?
    /// Nothing more will arrive: a picture was taken, or the person gave up.
    var onFinish: (() -> Void)?

    private let window = HostWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 1),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
    private let receiver = PictureReceiver()
    private var finished = false

    override init() {
        super.init()
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.contentView = receiver
        receiver.onImage = { [weak self] data, ext in self?.onImage?(data, ext) }
        receiver.onDone = { [weak self] in self?.finish() }
        NotificationCenter.default.addObserver(self, selector: #selector(sheetEnded),
                                               name: NSWindow.didEndSheetNotification, object: window)
    }

    /// The device menu has closed, with or without a choice.
    var onMenuClosed: (() -> Void)?

    /// Entries of our own, above the ones macOS adds for the devices: a file, the sample.
    private var entries: [(title: String, action: () -> Void)] = []
    private var chose = false

    func addEntry(_ title: String, action: @escaping () -> Void) {
        entries.append((title, action))
    }

    @objc private func picked(_ sender: NSMenuItem) {
        chose = true
        let action = entries[sender.tag].action
        // After the menu has gone: what follows may open a window of its own.
        DispatchQueue.main.async { [weak self] in
            action()
            self?.finish()
        }
    }

    /// Open the device menu where the mouse is now.
    ///
    /// Not at once. The app has to have the keyboard focus first: a menu opened while the focus
    /// is still on its way is closed by macOS when the focus arrives, which showed as a menu
    /// that only stayed open if the mouse button was held down.
    func show() {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 180, y: screen.visibleFrame.midY + 120))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(receiver)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.openMenu(at: mouse) }
    }

    private func openMenu(at mouse: NSPoint) {
        window.makeKey()
        window.makeFirstResponder(receiver)
        // An empty context menu for the receiving view. The entry is not ours to add: AppKit puts
        // "Import from iPhone or iPad" into the context menu of a view that takes pictures, and
        // an entry added by hand with that identifier is left as it is, grey ("Supporting
        // Continuity Camera in Your Mac App", Apple).
        let menu = NSMenu(title: "Add Photo")
        for (index, entry) in entries.enumerated() {
            let item = NSMenuItem(title: entry.title, action: #selector(picked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        let spot = window.convertPoint(fromScreen: mouse)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: spot, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else {
            onMenuClosed?()
            return finish()
        }
        NSMenu.popUpContextMenu(menu, with: event, for: receiver)
        onMenuClosed?()
        // If something was chosen, macOS hangs its waiting sheet from the window in a moment; if
        // nothing was, there is nothing to wait for.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.chose, self.window.attachedSheet == nil else { return }
            self.finish()
        }
    }

    /// The waiting sheet went away: the picture came, or the person pressed Cancel.
    @objc private func sheetEnded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        NotificationCenter.default.removeObserver(self)
        window.close()
        onFinish?()
    }
}

/// A window with no frame does not take the keyboard focus unless it says it will.
private final class HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The view that tells macOS "pictures can be put here", which is what makes it offer the iPhone.
private final class PictureReceiver: NSView, NSServicesMenuRequestor {
    var onImage: ((Data, String) -> Void)?
    var onDone: (() -> Void)?

    /// What is taken as it is, best first, and the extension each is filed under.
    private static let kinds: [(NSPasteboard.PasteboardType, String)] = [
        (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
        (NSPasteboard.PasteboardType("public.heic"), "heic"),
        (.png, "png"),
        (.tiff, "tiff"),
    ]
    private var asked = Set<String>()

    override var acceptsFirstResponder: Bool { true }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        // Any kind of picture, as AppKit names them. What macOS offers follows from the answers:
        // a photo comes as a JPEG, a sketch as a PNG, and a document scan as a PDF whatever is
        // said here (seen 2026-11-14), so a PDF is read too.
        if let returnType, NSImage.imageTypes.contains(returnType.rawValue) {
            if asked.insert(returnType.rawValue).inserted {
                Log.info("photo import: macOS asked whether \(returnType.rawValue) is taken; yes")
            }
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        let items = pasteboard.pasteboardItems ?? []
        let offered = items.map { $0.types.map(\.rawValue).joined(separator: " ") }
        Log.info("photo import: \(offered.count) item(s) arrived: \(offered.joined(separator: " | "))")
        var taken = 0
        for item in items {
            if let kind = Self.kinds.first(where: { item.data(forType: $0.0) != nil }),
               let data = item.data(forType: kind.0) {
                onImage?(data, kind.1)
                taken += 1
            } else if let pdf = item.data(forType: .pdf) {
                // A scan: one page of the PDF is one page of the notebook.
                for page in Self.pages(ofPDF: pdf) {
                    onImage?(page, "jpg")
                    taken += 1
                }
            }
        }
        // A kind that is in neither list: take it as whatever picture AppKit can read, and keep
        // it as a JPEG. Kept as it stood in memory it is tens of megabytes.
        if taken == 0, let image = NSImage(pasteboard: pasteboard),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
            onImage?(jpeg, "jpg")
            taken += 1
        }
        if taken == 0 { Log.warn("photo import: nothing in what arrived could be read as a picture") }
        onDone?()
        return taken > 0
    }

    func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }

    /// Each page of a scanned PDF as a JPEG at 200 dots to the inch. A PDF page read as a picture
    /// the plain way comes out at 72, which is too coarse to read handwriting from.
    static func pages(ofPDF data: Data) -> [Data] {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages > 0 else { return [] }
        let scale = 200.0 / 72.0
        return (1...document.numberOfPages).compactMap { number in
            guard let page = document.page(at: number) else { return nil }
            let box = page.getBoxRect(.mediaBox)
            let width = Int(box.width * scale), height = Int(box.height * scale)
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            guard let image = context.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: image)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }

}
