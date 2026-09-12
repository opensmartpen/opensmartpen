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

/// How many sheets are on screen and how they are arranged.
///
/// The binding decides the default — a pad is loose sheets, a bound notebook falls open at two —
/// but every layout is available for every notebook, because how you want to read something is
/// not always how it was bound.
enum ViewerLayout: String, CaseIterable, Identifiable {
    /// One sheet.
    case single
    /// Facing pages, paired as the book is bound: page 1 is a right-hand page.
    case spread
    /// Two sheets side by side, taken in order rather than paired. Turns one page at a time, so
    /// you can put any two pages next to each other.
    case pair
    /// Four sheets, two over two.
    case grid

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .single: return "rectangle.portrait"
        case .spread: return "book"
        case .pair: return "rectangle.split.2x1"
        case .grid: return "rectangle.split.2x2"
        }
    }

    var title: String {
        switch self {
        case .single: return "One page"
        case .spread: return "Facing pages"
        case .pair: return "Two across"
        case .grid: return "Four pages"
        }
    }

    /// Sheets across, and down.
    var shape: (columns: Int, rows: Int) {
        switch self {
        case .single: return (1, 1)
        case .spread, .pair: return (2, 1)
        case .grid: return (2, 2)
        }
    }

    static func `default`(for binding: KnownBooks.Binding) -> ViewerLayout {
        binding == .bound ? .spread : .single
    }
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
    /// How the sheets are arranged. Set from the notebook's binding the first time, and yours
    /// from then on — a layout you chose should not be undone by opening a different notebook.
    @Published var layout: ViewerLayout = .single {
        didSet { if layout != oldValue { chosenLayout = true; loadVisible() } }
    }
    private var chosenLayout = false
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
        let shape = layout.shape
        return (geometry.widthCells * Double(shape.columns))
            / (geometry.heightCells * Double(shape.rows))
    }

    /// The pages to offer in the pager: the ones that have ink on them.
    ///
    /// A notebook has 192 sheets and you have written on four. Offering the other 188 is offering
    /// blank paper — the pager would be mostly a way to look at nothing.
    var window: [Int] {
        let known = pages.contains(page) ? pages : (pages + [page]).sorted()
        guard known.count > 9, let here = known.firstIndex(of: page) else { return known }
        // Long notebooks get a window around where you are rather than the whole list.
        let start = min(max(0, here - 4), known.count - 9)
        return Array(known[start..<(start + 9)])
    }

    /// The next page with ink on it, in either direction — and outside whatever is already on
    /// screen, because turning a leaf of a spread shows two and stepping onto one of them would
    /// not move anything.
    private func neighbour(_ delta: Int) -> Int? {
        let onScreen = visible.compactMap { $0 }
        let candidates = delta > 0 ? pages.filter { $0 > (onScreen.max() ?? page) }
                                   : pages.filter { $0 < (onScreen.min() ?? page) }.reversed().map { $0 }
        return candidates.first
    }

    var canStep: (back: Bool, forward: Bool) { (neighbour(-1) != nil, neighbour(1) != nil) }

    /// Go straight to a page by its printed number.
    func go(to human: Int) {
        guard human >= 1 else { return }
        following = false
        page = human
        loadVisible()
    }

    var title: String {
        guard let book else { return "No pages yet" }
        return book.title
    }

    /// The sheets on screen, in reading order. A nil is a sheet that is physically there and has
    /// nothing on it — the left half of the first spread, which faces the inside cover.
    var visible: [Int?] {
        switch layout {
        case .single:
            return [page]
        case .spread:
            guard let book else { return [page] }
            let s = book.spread(containing: page)
            return [s.left, s.right]
        case .pair:
            return [page, page + 1]
        case .grid:
            if let book, book.binding == .bound {
                let first = book.spread(containing: page)
                let second = book.spread(containing: (first.right ?? page) + 1)
                return [first.left, first.right, second.left, second.right]
            }
            return [page, page + 1, page + 2, page + 3]
        }
    }

    /// What this notebook opens as, before you choose otherwise.
    var defaultLayout: ViewerLayout { .default(for: book?.binding ?? .pad) }

    /// True for any sheet on screen.
    func isOnScreen(_ human: Int) -> Bool { visible.contains(human) }

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
            if !chosenLayout {
                layout = .default(for: record?.binding ?? .pad)
                chosenLayout = false        // still the notebook's choice, not yours
            }
        }
        let human = record?.humanPage(ncode.page) ?? ncode.page
        page = human
        if !pages.contains(human) { pages = availablePages(for: ncode.bookKey) }
        loadVisible()
    }

    /// Load every sheet the current layout puts on screen.
    private func loadVisible() {
        for sheet in visible.compactMap({ $0 }) { loadIfNeeded(sheet) }
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
        case "1": layout = .single; return true
        case "2": layout = .spread; return true
        case "3": layout = .pair; return true
        case "4": layout = .grid; return true
        default: return false
        }
    }

    func step(_ delta: Int) {
        guard let next = neighbour(delta) else { return }
        go(to: next)
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
            let shape = viewer.layout.shape
            let gap: CGFloat = 10
            let available = CGSize(
                width: (geo.size.width - 34 - gap * CGFloat(shape.columns - 1)) / CGFloat(shape.columns),
                height: (geo.size.height - 34 - gap * CGFloat(shape.rows - 1)) / CGFloat(shape.rows))
            let slots = viewer.visible

            VStack(spacing: gap) {
                ForEach(0..<shape.rows, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<shape.columns, id: \.self) { column in
                            let index = row * shape.columns + column
                            if index < slots.count, let page = slots[index] {
                                Sheet(viewer: viewer, page: page, fit: available)
                            } else {
                                // The inside cover, or past the end. The gap is the sheet that
                                // is not there.
                                Color.clear.frame(width: available.width, height: available.height)
                            }
                        }
                    }
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
                .disabled(!viewer.canStep.back)

            // A range rather than a single number: you can see where you are in the notebook and
            // jump a few pages without paging one at a time.
            HStack(spacing: 2) {
                ForEach(viewer.window, id: \.self) { n in
                    PageChip(number: n,
                             current: viewer.isOnScreen(n),
                             // Only worth marking when you are somewhere else: on the page you
                             // are already looking at, the violet edge on the sheet says it.
                             active: viewer.activeIsHere && viewer.activePage == n
                                     && !viewer.isOnScreen(n)) {
                        viewer.go(to: n)
                    }
                }
            }

            Button { viewer.step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(!viewer.canStep.forward)

            Spacer(minLength: 8)

            Picker("", selection: $viewer.layout) {
                ForEach(ViewerLayout.allCases) { option in
                    Image(systemName: option.symbol).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("How the pages are arranged (1–4)")

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
        // Double-click a sheet to have it to yourself, and again to go back to the layout.
        .onTapGesture(count: 2) {
            viewer.layout = viewer.layout == .single ? viewer.defaultLayout : .single
            viewer.go(to: page)
        }
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
    /// The window keeps whatever size you give it, but it has to start somewhere sensible.
    private var hasSized = false
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

    /// Size the window to the paper.
    ///
    /// The first time it opens there is nothing to take a size from, so it is taken from the
    /// screen: a document window that appears at 240 points on a 2000 point display is not a
    /// choice anybody made. After that the size is yours, and only the proportions are enforced —
    /// switching a bound notebook between a spread and a single sheet changes the width and leaves
    /// the height where you put it.
    func fit(initial: Bool = false) {
        guard let window else { return }
        let paper = viewer.aspect
        guard paper > 0 else { return }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Height carries the bar as well as the sheet, so the locked ratio is the paper's adjusted
        // for it. Any residual difference is absorbed by the letterboxing the canvas already does.
        var height: CGFloat
        if initial {
            height = min(visible.height * 0.82, 940)
        } else {
            height = window.contentLayoutRect.height
        }
        height = max(window.minSize.height, height)
        var width = (height - Self.barHeight) * paper

        // A spread on a narrow screen would otherwise run off both sides.
        let maxWidth = visible.width * 0.92
        if width > maxWidth {
            width = maxWidth
            height = width / paper + Self.barHeight
        }

        window.contentAspectRatio = NSSize(width: width, height: height)
        window.setContentSize(NSSize(width: width, height: height))
        if initial { window.center() }
    }

    override func showWindow(_ sender: Any?) {
        let first = !hasSized
        hasSized = true
        super.showWindow(sender)
        window?.title = viewer.title
        fit(initial: first)
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
