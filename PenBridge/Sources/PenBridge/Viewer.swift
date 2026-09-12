import AppKit
import PenBridgeCore
import SwiftUI

/// One stroke, ready to draw: the points, and the ink it was made with.
///
/// Colour and width are resolved once, when the stroke is loaded, by asking the mode log what was
/// in force at the moment it was written. The same join the renderer does — so what you see here
/// and what lands in the PNG come from one rule rather than two.
/// A point with the width the line has there. Width is resolved once, at load, through
/// `Palette.width(for:force:)` — the one definition of how pressure widens a line, shared with
/// render.py through palette.json. A second curve here is how the preview and the page start to
/// disagree by a little, always.
struct InkPoint: Equatable {
    var x: Double
    var y: Double
    /// In Ncode cells, so it scales with the paper rather than with the window.
    var width: Double
}

struct DrawnStroke: Equatable {
    var points: [InkPoint]
    var colour: Color
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
    /// Which notebook the pen is in, so the pager only marks the active page when it is this one.
    @Published private(set) var activeBook: String?
    /// While true, the viewer follows the pen instead of staying where you paged to.
    @Published var following = true
    /// A bound notebook shows both halves unless you ask for one.
    @Published var focused = false
    @Published private(set) var strokes: [Int: [DrawnStroke]] = [:]
    /// The stroke under the pen, kept apart so it can be drawn before it is finished.
    @Published private(set) var wet: [InkPoint] = []
    @Published private(set) var wetPage: Int?

    private let books: BookRegistry
    private let repo: URL
    private var modeLog: ModeLog?
    private var palette = Palette()
    private var bookKey: String?
    private var pending: [InkPoint] = []
    private var flushing = false

    init(books: BookRegistry, repo: URL) {
        self.books = books
        self.repo = repo
    }

    func attach(modeLog: ModeLog?) { self.modeLog = modeLog }

    var geometry: PageGeometry { book?.geometry ?? .a4 }

    /// One line width, in cells, through the shared curve.
    private func cells(_ weight: LineWidth, force: Double) -> Double {
        (palette.width(for: weight, force: force) ?? 0.29) / PageGeometry.mmPerCell
    }

    /// What the stroke under the pen is drawn with: whatever is selected right now.
    var wetColour: Color {
        Color(inkHex: palette.hex(for: modeLog?.current.ink ?? .black)) ?? .black
    }

    /// The width a line would have right now at typical pressure, for sizing decisions that
    /// cannot ask a particular dot.
    var typicalWidth: Double { cells(modeLog?.current.width ?? .default, force: 0.7) }

    /// The shape of what is on screen: one sheet, or two side by side. The window opens at these
    /// proportions so the paper arrives looking like the paper.
    var aspect: Double {
        let sheets = spread.left == nil ? 1.0 : 2.0
        return (geometry.widthCells * sheets) / geometry.heightCells
    }

    /// The run of page numbers to offer in the pager, centred on where you are and never running
    /// off the front of the notebook.
    var window: [Int] {
        let span = 7
        let known = max(pages.last ?? page, page, activePage ?? 1)
        var start = max(1, page - span / 2)
        if start + span - 1 > max(known, span) { start = max(1, max(known, span) - span + 1) }
        return Array(start..<(start + span))
    }

    /// True for either half of the spread on screen, so both are lit in the pager.
    func isOnScreen(_ human: Int) -> Bool {
        let s = spread
        return s.left == human || s.right == human
    }

    /// Go straight to a page by its printed number.
    func go(to human: Int) {
        guard human >= 1 else { return }
        following = false
        page = human
        loadIfNeeded(human)
        if let other = spread.left, other != human { loadIfNeeded(other) }
    }

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
    /// Back to whatever was written last, wherever it was — including a different notebook, which
    /// is why the button does not say "live": it is not a mode, it is a jump.
    func goLatest() {
        following = true
        if let recent = books.recentPages(limit: 1).first { show(page: recent.page) }
        else if let active = activePage { page = active; loadIfNeeded(active) }
    }

    /// True when the pager's active mark belongs to the notebook on screen.
    var activeIsHere: Bool { activeBook == nil || activeBook == bookKey }

    /// Keyboard, handled by the window: arrows page, H goes home to the live page, F changes how
    /// a bound notebook is shown.
    func handle(key: String) -> Bool {
        switch key {
        case "h", "H": goLatest(); return true
        case "f", "F": focused.toggle(); return true
        default: return false
        }
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
        return DrawnStroke(
            points: stroke.dots.map {
                InkPoint(x: $0.x, y: $0.y, width: cells(state.width, force: $0.force))
            },
            // An ink with no colour assigned draws black, and the panel is what says so — here it
            // would be a silent substitution nobody could see.
            colour: Color(inkHex: hex) ?? .black)
    }

    // MARK: live

    /// One dot from the pen, ahead of stroke assembly: a stroke is only finished on pen-up, and
    /// waiting for that would make writing appear a word at a time.
    func receive(page id: PageID, dot: DotSample, event: DotEvent) {
        let human = books.record(for: id)?.humanPage(id.page) ?? id.page
        activeBook = id.bookKey
        activePage = human
        // Only follow the pen if you asked to. Writing in another notebook while you are reading
        // this one should not pull the window out from under you.
        if following {
            if id.bookKey != bookKey { show(page: id) }
            else if human != page {
                page = human
                loadIfNeeded(human)
            }
        }
        if wetPage != human { flush(); wetPage = human }

        switch event {
        case .down:
            flush()
            wet = [InkPoint(x: dot.x, y: dot.y, width: wetWidth(dot))]
        case .move:
            pending.append(InkPoint(x: dot.x, y: dot.y, width: wetWidth(dot)))
            schedule()
        case .up:
            flush()
            wet.append(InkPoint(x: dot.x, y: dot.y, width: wetWidth(dot)))
            settle(human)
        }
    }

    private func wetWidth(_ dot: DotSample) -> Double {
        cells(modeLog?.current.width ?? .default, force: dot.force)
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
        strokes[human, default: []].append(
            DrawnStroke(points: wet, colour: Color(inkHex: palette.hex(for: state.ink)) ?? .black))
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

            Button { viewer.step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(viewer.page <= 1)

            // A range rather than a single number: you can see where you are in the notebook and
            // jump a few pages without paging one at a time.
            HStack(spacing: 2) {
                ForEach(viewer.window, id: \.self) { n in
                    PageChip(number: n,
                             current: viewer.isOnScreen(n),
                             active: viewer.activeIsHere && viewer.activePage == n) {
                        viewer.go(to: n)
                    }
                }
            }

            Button { viewer.step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)

            Spacer(minLength: 8)

            if viewer.book?.binding == .bound {
                Button { viewer.focused.toggle() } label: {
                    Image(systemName: viewer.focused ? "book" : "doc")
                }
                .buttonStyle(.borderless)
                .help(viewer.focused ? "Both pages (F)" : "One page (F)")
            }

            // One click back to whatever the pen touched last — the page you almost always want.
            Button(action: viewer.goLatest) {
                HStack(spacing: 4) {
                    Circle().fill(viewer.following ? Ink.accent : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text("Latest").font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            .help("The last page written, in any notebook (H)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial)
    }
}

/// One page number in the pager. Violet marks the page the pen touched last, which is the one you
/// are usually trying to get back to.
private struct PageChip: View {
    let number: Int
    let current: Bool
    let active: Bool
    let go: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: go) {
            Text("\(number)")
                .font(.system(size: 10.5, weight: current ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(current ? Color.primary : Color.secondary)
                .frame(minWidth: 19)
                .padding(.vertical, 2.5)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(current ? Color.primary.opacity(0.12)
                          : hovering ? Color.primary.opacity(0.06) : Color.clear))
                .overlay(alignment: .bottom) {
                    if active {
                        Circle().fill(Ink.accent).frame(width: 3, height: 3).offset(y: 2.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One sheet of paper at its real proportions, with the ink that is on it.
private struct Sheet: View {
    @ObservedObject var viewer: Viewer
    let page: Int
    let fit: CGSize

    private var isActive: Bool { viewer.activeIsHere && viewer.activePage == page }

    var body: some View {
        let g = viewer.geometry
        let scale = min(fit.width / g.widthCells, fit.height / g.heightCells)
        let size = CGSize(width: g.widthCells * scale, height: g.heightCells * scale)

        // At small sizes the thinnest line would disappear. Rather than clamping each weight
        // independently — which makes thin and thick the same line and throws away the whole point
        // of having weights — every line on the page is lifted by one shared factor, so the
        // ratios between them survive.
        let thinnest = (viewer.strokes[page] ?? [])
            .compactMap { $0.points.map(\.width).min() }.min() ?? viewer.typicalWidth
        let lift = max(1, 0.55 / max(0.0001, thinnest * scale))

        Canvas { context, _ in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for stroke in viewer.strokes[page] ?? [] {
                draw(stroke.points, in: context, scale: scale, colour: stroke.colour, lift: lift)
            }
            if viewer.wetPage == page {
                draw(viewer.wet, in: context, scale: scale, colour: viewer.wetColour, lift: lift)
            }
        }
        .frame(width: max(1, size.width), height: max(1, size.height))
        .overlay(Rectangle().stroke(isActive ? Ink.accent : Color.black.opacity(0.13),
                                    lineWidth: isActive ? 1.5 : 0.5))
        .shadow(color: .black.opacity(0.18), radius: 7, y: 2)
        .onTapGesture { viewer.focused.toggle() }
    }

    /// Ink is drawn segment by segment because its width changes along the stroke: the pen
    /// reports force per dot and the renderer widens the line by it, so a flat line here would
    /// read heavier than the page it is previewing.
    private func draw(_ points: [InkPoint], in context: GraphicsContext,
                      scale: Double, colour: Color, lift: Double) {
        guard let first = points.first else { return }
        func width(_ p: InkPoint) -> Double { max(0.35, p.width * scale * lift) }

        // A dot is a position, not a segment, so a single tap would otherwise draw nothing.
        if points.count == 1 {
            let r = width(first) / 2
            context.fill(Path(ellipseIn: CGRect(x: first.x * scale - r, y: first.y * scale - r,
                                                width: r * 2, height: r * 2)), with: .color(colour))
            return
        }
        for (a, b) in zip(points, points.dropFirst()) {
            var seg = Path()
            seg.move(to: CGPoint(x: a.x * scale, y: a.y * scale))
            seg.addLine(to: CGPoint(x: b.x * scale, y: b.y * scale))
            context.stroke(seg, with: .color(colour),
                           style: StrokeStyle(lineWidth: (width(a) + width(b)) / 2,
                                              lineCap: .round, lineJoin: .round))
        }
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

/// Resizable, floating so it survives being presented over, and locked to the shape of the paper.
final class ViewerWindowController: NSWindowController {
    private let viewer: Viewer
    /// The bar along the bottom, which is not paper and has to be allowed for when the window is
    /// locked to the paper's proportions.
    private static let barHeight: CGFloat = 31

    init(viewer: Viewer) {
        self.viewer = viewer
        let window = ViewerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ViewerView(viewer: viewer))
        window.setFrameAutosaveName("penbridge-viewer")
        window.minSize = NSSize(width: 320, height: 260)
        window.level = .floating
        window.collectionBehavior = [.managed, .fullScreenAuxiliary]
        super.init(window: window)
        window.onKey = { [weak self] key in self?.key(key) ?? false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func key(_ key: String) -> Bool {
        switch key {
        case "\u{F702}": viewer.step(-1)          // left arrow
        case "\u{F703}": viewer.step(1)           // right arrow
        default:
            guard viewer.handle(key: key) else { return false }
        }
        fit()
        return true
    }

    /// Open at the paper's own proportions rather than at whatever the last window happened to be,
    /// and lock resizing to them so a dragged corner keeps the page the right shape.
    func fit() {
        guard let window else { return }
        let paper = viewer.aspect
        guard paper > 0 else { return }

        // Height carries the bar as well as the sheet, so the locked ratio is the paper's adjusted
        // for it. Any residual difference is absorbed by the letterboxing the canvas already does.
        let width = max(window.minSize.width, window.contentLayoutRect.width)
        let height = width / paper + Self.barHeight
        window.contentAspectRatio = NSSize(width: width, height: height)

        var target = NSSize(width: width, height: height)
        if let visible = window.screen?.visibleFrame {
            let cap = min(visible.height - 60, target.height)
            if cap < target.height {
                target = NSSize(width: (cap - Self.barHeight) * paper, height: cap)
            }
        }
        window.setContentSize(target)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.title = viewer.title
        fit()
    }

    /// The window is named for the notebook in it, not for the app.
    func retitle() { window?.title = viewer.title }
}

/// A window that hands keystrokes to the viewer before AppKit beeps at them.
private final class ViewerWindow: NSWindow {
    var onKey: ((String) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if let characters = event.charactersIgnoringModifiers,
           !event.modifierFlags.contains(.command),
           onKey?(characters) == true { return }
        super.keyDown(with: event)
    }
}
