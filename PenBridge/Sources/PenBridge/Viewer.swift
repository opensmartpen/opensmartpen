import AppKit
import PenBridgeCore
import SwiftUI

/// One stroke, ready to draw: the points, and the ink it was made with.
///
/// Colour and width are resolved once, when the stroke is loaded, by asking the mode log what was
/// in force at the moment it was written. The same join the renderer does — so what you see here
/// and what lands in the PNG come from one rule rather than two.
struct DrawnStroke: Equatable {
    var points: [CGPoint]
    var colour: Color
    /// In Ncode cells, so it scales with the page rather than with the window.
    var weight: Double
}

/// Everything the viewer shows. One object serves both jobs — the page under your pen right now,
/// and any page you page back to — because they are the same thing seen at different moments, and
/// two viewers would be two chances to disagree about what a page looks like.
final class Viewer: ObservableObject {
    @Published private(set) var book: BookRecord?
    /// Human page numbers present in this notebook, ascending.
    @Published private(set) var pages: [Int] = []
    /// The human page the viewer is looking at. For a bound notebook this is one half of a spread.
    @Published private(set) var page: Int = 1
    /// The page most recently written to, anywhere. The one you get back to with one click.
    @Published private(set) var activePage: Int?
    /// While true, the viewer follows the pen instead of staying where you paged to.
    @Published var following = true
    /// A bound notebook shows both halves unless you ask for one.
    @Published var focused = false
    @Published private(set) var strokes: [Int: [DrawnStroke]] = [:]
    /// The stroke under the pen, kept apart so it can be drawn before it is finished.
    @Published private(set) var wet: [CGPoint] = []
    @Published private(set) var wetPage: Int?

    private let books: BookRegistry
    private let repo: URL
    private var modeLog: ModeLog?
    private var palette = Palette()
    private var bookKey: String?
    private var pending: [CGPoint] = []
    private var flushing = false

    init(books: BookRegistry, repo: URL) {
        self.books = books
        self.repo = repo
    }

    func attach(modeLog: ModeLog?) { self.modeLog = modeLog }

    var geometry: PageGeometry { book?.geometry ?? .a4 }

    var title: String {
        guard let book else { return "No pages yet" }
        return book.title
    }

    /// The two halves on screen. A pad has only a right-hand page, which is simply "the page".
    var spread: (left: Int?, right: Int?) {
        guard let book, !focused else { return (nil, page) }
        return book.spread(containing: page)
    }

    // MARK: loading

    /// Point the viewer at a page, loading the notebook around it.
    func show(page ncode: PageID) {
        let record = books.record(for: ncode)
        if bookKey != ncode.bookKey {
            bookKey = ncode.bookKey
            book = record
            palette = Palette.load(root: repo)
            strokes = [:]
            pages = availablePages(for: ncode.bookKey)
        }
        let human = record?.humanPage(ncode.page) ?? ncode.page
        page = human
        if !pages.contains(human) { pages = availablePages(for: ncode.bookKey) }
        loadIfNeeded(human)
        if let other = spread.left, other != human { loadIfNeeded(other) }
    }

    /// Jump back to whatever was written last, and follow it from now on.
    func goLive() {
        following = true
        if let active = activePage { page = active; loadIfNeeded(active) }
        else if let recent = books.recentPages(limit: 1).first { show(page: recent.page) }
    }

    func step(_ delta: Int) {
        guard let book else { return }
        // A bound notebook turns a leaf at a time, which is two pages, not one.
        let stride = book.binding == .bound && !focused ? 2 : 1
        let next = page + delta * stride
        guard next >= 1 else { return }
        following = false
        page = next
        loadIfNeeded(next)
        if let other = spread.left, other != next { loadIfNeeded(other) }
    }

    private func availablePages(for key: String) -> [Int] {
        guard let record = book else { return [] }
        let found = books.recentPages(limit: 500)
            .filter { $0.page.bookKey == key }
            .map { record.humanPage($0.page.page) }
        return Array(Set(found)).sorted()
    }

    private func ncode(for human: Int) -> PageID? {
        guard let book, let first = bookKey else { return nil }
        let parts = first.split(separator: "/").map { Int($0.dropFirst()) ?? 0 }
        guard parts.count == 3 else { return nil }
        return PageID(section: parts[0], owner: parts[1], book: parts[2],
                      page: human + book.firstPage - 1)
    }

    private func loadIfNeeded(_ human: Int) {
        guard strokes[human] == nil, let id = ncode(for: human) else { return }
        let raw = RawReader.strokes(at: books.rawFile(for: id))
        strokes[human] = raw.map { drawn($0) }
    }

    /// Resolve one raw stroke into something drawable. The pen always reports black, so the colour
    /// comes from the mode log at the stroke's own time — never from the stroke itself.
    private func drawn(_ stroke: Stroke) -> DrawnStroke {
        let state = modeLog?.state(at: stroke.start) ?? (ink: .black, width: .default)
        let hex = palette.hex(for: state.ink)
        let mm = palette.width(for: state.width) ?? 0.29
        return DrawnStroke(points: stroke.dots.map { CGPoint(x: $0.x, y: $0.y) },
                           // An ink with no colour assigned draws black, and the panel is what
                           // says so — here it would be a silent substitution nobody could see.
                           colour: Color(inkHex: hex) ?? .black,
                           weight: mm / PageGeometry.mmPerCell)
    }

    // MARK: live

    /// One dot from the pen, ahead of stroke assembly: a stroke is only finished on pen-up, and
    /// waiting for that would make writing appear a word at a time.
    func receive(page id: PageID, dot: DotSample, event: DotEvent) {
        let human = books.record(for: id)?.humanPage(id.page) ?? id.page
        activePage = human
        if id.bookKey != bookKey { show(page: id) }
        else if following && human != page {
            page = human
            loadIfNeeded(human)
        }
        if wetPage != human { flush(); wetPage = human }

        switch event {
        case .down:
            flush()
            wet = [CGPoint(x: dot.x, y: dot.y)]
        case .move:
            pending.append(CGPoint(x: dot.x, y: dot.y))
            schedule()
        case .up:
            flush()
            wet.append(CGPoint(x: dot.x, y: dot.y))
            settle(human)
        }
    }

    /// Dots land at up to 120/s. Publishing each one would redraw far more often than the display
    /// can show it, so the wet stroke is flushed on a display-rate timer.
    private func schedule() {
        guard !flushing else { return }
        flushing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            self?.flushing = false
            self?.flush()
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        wet.append(contentsOf: pending)
        pending = []
    }

    /// A finished stroke joins the page, taking whatever ink is in force right now.
    private func settle(_ human: Int) {
        guard !wet.isEmpty else { return }
        let state = modeLog?.current ?? (ink: .black, width: .default)
        let mm = palette.width(for: state.width) ?? 0.29
        strokes[human, default: []].append(
            DrawnStroke(points: wet, colour: Color(inkHex: palette.hex(for: state.ink)) ?? .black,
                        weight: mm / PageGeometry.mmPerCell))
        wet = []
        if !pages.contains(human) { pages.append(human); pages.sort() }
    }
}

// MARK: - view

struct ViewerView: View {
    @ObservedObject var viewer: Viewer

    var body: some View {
        VStack(spacing: 0) {
            sheets
            bar
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var sheets: some View {
        GeometryReader { geo in
            let spread = viewer.spread
            let count = (spread.left == nil ? 0 : 1) + (spread.right == nil ? 0 : 1)
            let gap: CGFloat = 10
            let available = CGSize(width: (geo.size.width - 34 - gap * CGFloat(max(0, count - 1)))
                                    / CGFloat(max(1, count)),
                                   height: geo.size.height - 34)
            HStack(spacing: gap) {
                if let left = spread.left {
                    Sheet(viewer: viewer, page: left, fit: available)
                }
                if let right = spread.right {
                    Sheet(viewer: viewer, page: right, fit: available)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Text(viewer.title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 8)

            if viewer.book?.binding == .bound {
                Toggle(isOn: $viewer.focused) { Image(systemName: "rectangle.portrait") }
                    .toggleStyle(.button)
                    .help(viewer.focused ? "Show both pages" : "Show one page")
            }

            Button { viewer.step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(viewer.page <= 1)
            Text(label)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 58)
            Button { viewer.step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)

            // One click back to whatever the pen touched last — the page you almost always want.
            Button(action: viewer.goLive) {
                HStack(spacing: 4) {
                    Circle().fill(viewer.following ? Ink.accent : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text("Live").font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            .disabled(viewer.following && viewer.activePage == viewer.page)
            .help("Go to the page being written")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial)
    }

    private var label: String {
        let spread = viewer.spread
        if let l = spread.left, let r = spread.right { return "\(l)–\(r)" }
        return "\(spread.right ?? viewer.page)"
    }
}

/// One sheet of paper at its real proportions, with the ink that is on it.
private struct Sheet: View {
    @ObservedObject var viewer: Viewer
    let page: Int
    let fit: CGSize

    private var isActive: Bool { viewer.activePage == page }

    var body: some View {
        let g = viewer.geometry
        let scale = min(fit.width / g.widthCells, fit.height / g.heightCells)
        let size = CGSize(width: g.widthCells * scale, height: g.heightCells * scale)

        Canvas { context, _ in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for stroke in viewer.strokes[page] ?? [] {
                draw(stroke.points, in: context, scale: scale,
                     colour: stroke.colour, weight: stroke.weight)
            }
            if viewer.wetPage == page {
                draw(viewer.wet, in: context, scale: scale, colour: .black, weight: 0.29 / PageGeometry.mmPerCell)
            }
        }
        .frame(width: max(1, size.width), height: max(1, size.height))
        .overlay(Rectangle().stroke(isActive ? Ink.accent : Color.black.opacity(0.13),
                                    lineWidth: isActive ? 1.5 : 0.5))
        .shadow(color: .black.opacity(0.18), radius: 7, y: 2)
        .onTapGesture { viewer.focused.toggle() }
    }

    /// A dot is a position, not a segment, so a single tap would otherwise draw nothing.
    private func draw(_ points: [CGPoint], in context: GraphicsContext,
                      scale: Double, colour: Color, weight: Double) {
        guard let first = points.first else { return }
        let line = max(0.6, weight * scale)
        if points.count == 1 {
            let r = line / 2
            context.fill(Path(ellipseIn: CGRect(x: first.x * scale - r, y: first.y * scale - r,
                                                width: r * 2, height: r * 2)), with: .color(colour))
            return
        }
        var path = Path()
        path.move(to: CGPoint(x: first.x * scale, y: first.y * scale))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * scale, y: point.y * scale))
        }
        context.stroke(path, with: .color(colour),
                       style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
    }
}

extension Color {
    init?(inkHex hex: String?) {
        guard var h = hex else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

/// Resizable, floating so it survives being presented over, and big enough for a spread.
final class ViewerWindowController: NSWindowController {
    convenience init(viewer: Viewer) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "PenBridge"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ViewerView(viewer: viewer))
        window.setFrameAutosaveName("penbridge-viewer")
        window.center()
        // Above ordinary windows so it stays visible while presenting from another app, but not
        // above everything: a screen-sharing toolbar should still be reachable.
        window.level = .floating
        window.collectionBehavior = [.managed, .fullScreenAuxiliary]
        self.init(window: window)
    }
}
