import AppKit
import OpenSmartPenCore
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
public final class Viewer: ObservableObject {
    @Published private(set) var book: BookRecord?
    /// Human page numbers present in this notebook, ascending.
    @Published private(set) var pages: [Int] = []
    /// The human page the viewer is looking at. For a bound notebook this is one half of a spread.
    @Published private(set) var page: Int = 1 {
        didSet { if page != oldValue { refreshTranscript() } }
    }
    /// The page most recently written to, anywhere. The one you get back to with one click.
    @Published private(set) var activePage: Int?
    /// Which notebook the pen is in, so the pager only marks the active page when it is this one.
    @Published private(set) var activeBook: String?
    /// While true, the viewer follows the pen instead of staying where you paged to.
    @Published var following = true
    /// How the sheets are arranged. Set from the notebook's binding the first time, and yours
    /// from then on — a layout you chose should not be undone by opening a different notebook.
    @Published var layout: ViewerLayout = .single {
        didSet { if layout != oldValue { chosenLayout = true; pan = .zero; loadVisible() } }
    }
    private var chosenLayout = false
    /// How much larger than a fitted sheet the paper is drawn. 1 is the whole sheet in the window.
    /// Kept across page turns: you zoom in to read a hand, and the next page is in the same hand.
    @Published private(set) var zoom: Double = 1
    /// The zoom the ink was last drawn at. While a zoom is under way the drawing is only
    /// stretched to `zoom`, which costs nothing, and it is drawn again, sharp, once the zoom has
    /// stopped. Drawing every stroke again for every step of a pinch is what made zooming
    /// stutter: a full page is thousands of segments, and a gesture asks for sixty a second.
    @Published private(set) var drawnZoom: Double = 1
    private var sharpen: DispatchWorkItem?
    /// Where the paper has been dragged to, in points, away from the middle of the window.
    @Published private(set) var pan: CGSize = .zero
    /// The area the sheets are drawn in. The view owns this number — it is the only one that
    /// knows it — and the model needs it to keep zoom anchored and pan honest.
    private(set) var viewport: CGSize = .zero
    @Published private(set) var strokes: [Int: [DrawnStroke]] = [:]
    /// The stroke under the pen, kept apart so it can be drawn before it is finished.
    @Published private(set) var wet: [InkPoint] = []
    @Published private(set) var wetPage: Int?

    private let books: BookRegistry
    private let repo: URL
    private var modeLog: ModeLog?
    private var palette = Palette()
    /// The copy on screen. A copy, not a product: two pads of the same kind are two notebooks
    /// here, because they are two notebooks on the desk (ADR-002).
    private var folder: BookFolder?
    private var pending: [InkPoint] = []
    private var flushing = false

    public init(books: BookRegistry, repo: URL) {
        self.books = books
        self.repo = repo
    }

    public func attach(modeLog: ModeLog?) { self.modeLog = modeLog }

    // MARK: transcript

    /// Where transcripts come from. The app does not make them: whatever reads the bucket does,
    /// and this fetches the one for the page on screen. Nil in a viewer with no bucket behind it.
    public var transcripts: TranscriptStore?
    /// The pane beside the paper. Remembered, because wanting the text next to the ink is a
    /// habit, not a decision made again each time.
    @Published var showsTranscript = UserDefaults.standard.bool(forKey: "viewer.transcript") {
        didSet {
            guard showsTranscript != oldValue else { return }
            UserDefaults.standard.set(showsTranscript, forKey: "viewer.transcript")
            onTranscriptToggle?(showsTranscript)
            refreshTranscript()
        }
    }
    @Published private(set) var transcript: Transcript = .none
    @Published private(set) var fetchingTranscript = false
    private var transcriptPage: PageRef?
    /// Set by the window, which makes room for the pane rather than taking it from the paper.
    var onTranscriptToggle: ((Bool) -> Void)?
    static let transcriptWidth: CGFloat = 340

    /// Show what this Mac already has for the page, at once, and ask the bucket for the latest.
    /// Called when the page changes and every so often while the pane is open: a transcript
    /// arrives a minute or two after the writing, with nothing to announce it.
    func refreshTranscript() {
        guard showsTranscript, let store = transcripts, let ref = ref(for: page) else {
            transcriptPage = nil
            return
        }
        if transcriptPage != ref {
            transcriptPage = ref
            transcript = store.cached(for: ref)
        }
        fetchingTranscript = true
        store.fetch(for: ref) { [weak self] answer in
            guard let self, self.transcriptPage == ref else { return }
            self.fetchingTranscript = false
            if self.transcript != answer { self.transcript = answer }
        }
    }

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

    // MARK: zoom

    /// The space around the sheets, and between them. Here rather than in the view because pan
    /// has to know how big the paper is to know how far it may be dragged.
    static let gap: CGFloat = 10
    static let margin: CGFloat = 34
    /// Past about eight the dots themselves are the picture, not the writing.
    static let zoomRange: ClosedRange<Double> = 1...8

    var canZoomIn: Bool { zoom < Self.zoomRange.upperBound - 0.001 }
    var canZoomOut: Bool { zoom > Self.zoomRange.lowerBound + 0.001 }

    /// One sheet at fit: the paper's own proportions inside the share of the window its slot gets.
    func fittedSheet(in viewport: CGSize) -> CGSize {
        let shape = layout.shape
        let across = max(1, CGFloat(shape.columns)), down = max(1, CGFloat(shape.rows))
        let width = max(1, (viewport.width - Self.margin - Self.gap * (across - 1)) / across)
        let height = max(1, (viewport.height - Self.margin - Self.gap * (down - 1)) / down)
        let g = geometry
        let scale = min(width / g.widthCells, height / g.heightCells)
        return CGSize(width: max(1, g.widthCells * scale), height: max(1, g.heightCells * scale))
    }

    /// Everything on screen, at the zoom in force.
    private var content: CGSize {
        let sheet = fittedSheet(in: viewport)
        let shape = layout.shape
        return CGSize(
            width: (sheet.width * CGFloat(shape.columns) + Self.gap * CGFloat(shape.columns - 1)) * zoom,
            height: (sheet.height * CGFloat(shape.rows) + Self.gap * CGFloat(shape.rows - 1)) * zoom)
    }

    func setViewport(_ size: CGSize) {
        guard size != viewport else { return }
        viewport = size
        clampPan()
    }

    /// Zoom about a point in the viewport — the pointer for a wheel or a pinch, the middle for
    /// anything else — so that what you are pointing at is still under the pointer afterwards.
    /// Zooming about the middle instead would walk the thing you wanted off the edge.
    func setZoom(_ factor: Double, about anchor: CGPoint? = nil) {
        let next = min(max(factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard abs(next - zoom) > 0.0001 else { return }
        let middle = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let a = anchor ?? middle
        let ratio = next / zoom
        // The paper under the anchor must not move: pan grows with the zoom around that point.
        pan = CGSize(width: (pan.width - (a.x - middle.x)) * ratio + (a.x - middle.x),
                     height: (pan.height - (a.y - middle.y)) * ratio + (a.y - middle.y))
        zoom = next
        clampPan()
        sharpenSoon()
    }

    func zoomBy(_ factor: Double, about anchor: CGPoint? = nil) {
        setZoom(zoom * factor, about: anchor)
    }

    /// One step from the keyboard, about the middle, eased rather than snapped: a jump of a
    /// quarter is easy to lose your place in.
    func zoomStep(_ factor: Double) {
        withAnimation(.easeOut(duration: 0.16)) { zoomBy(factor) }
    }

    /// The whole page again, in the middle.
    func zoomToFit() {
        guard zoom != 1 || pan != .zero else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            zoom = 1
            pan = .zero
        }
        sharpenSoon()
    }

    /// Draw the ink again at the zoom now in force, a moment after the zoom last moved.
    private func sharpenSoon() {
        sharpen?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.drawnZoom != self.zoom else { return }
            self.drawnZoom = self.zoom
        }
        sharpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func setPan(_ offset: CGSize) {
        pan = offset
        clampPan()
    }

    /// The paper cannot be dragged away from the window: you may move it by as much as it
    /// overflows and no further, which is nothing at all when the whole page is already showing.
    private func clampPan() {
        guard viewport.width > 0, viewport.height > 0 else { return }
        let over = content
        let slackX = max(0, (over.width - viewport.width) / 2)
        let slackY = max(0, (over.height - viewport.height) / 2)
        pan = CGSize(width: min(max(pan.width, -slackX), slackX),
                     height: min(max(pan.height, -slackY), slackY))
    }

    // MARK: loading

    /// Point the viewer at a page, loading the notebook around it.
    public func show(page ref: PageRef) {
        let record = books.record(for: ref)
        if folder != ref.folder {
            folder = ref.folder
            book = record
            palette = Palette.load(root: repo)
            strokes = [:]
            pages = availablePages(in: ref.folder)
            if !chosenLayout {
                layout = .default(for: record?.binding ?? .pad)
                chosenLayout = false        // still the notebook's choice, not yours
            }
        }
        let human = record?.humanPage(ref.page.page) ?? ref.page.page
        page = human
        if !pages.contains(human) { pages = availablePages(in: ref.folder) }
        loadVisible()
        // The same page number in another notebook is another page.
        refreshTranscript()
    }

    /// Read these pages from disk again. A page loaded before a drain lacks the strokes the pen
    /// kept while it had no link: they arrive after the first live ones, and only on disk.
    public func reload(_ refs: Set<PageRef>) {
        guard let folder, let book else { return }
        for ref in refs where ref.folder == folder {
            let human = book.humanPage(ref.page.page)
            guard strokes[human] != nil else { continue }
            strokes[human] = nil
            if isOnScreen(human) { loadIfNeeded(human) }
        }
    }

    /// Load every sheet the current layout puts on screen.
    private func loadVisible() {
        for sheet in visible.compactMap({ $0 }) { loadIfNeeded(sheet) }
    }

    /// Jump back to whatever was written last, and follow it from now on.
    /// Back to whatever was written last, wherever it was — including a different notebook, which
    /// is why the button does not say "live": it is not a mode, it is a jump.
    public func goLatest() {
        following = true
        if let recent = books.recentPages(limit: 1).first { show(page: recent.page) }
        else if let active = activePage { page = active; loadIfNeeded(active) }
    }

    /// True when the pager's active mark belongs to the notebook on screen.
    var activeIsHere: Bool { activeBook == nil || activeBook == folder?.name }

    /// Keyboard, handled by the window: arrows page, H goes home to the live page, F changes how
    /// a bound notebook is shown.
    func handle(key: String) -> Bool {
        switch key {
        case "h", "H": goLatest(); return true
        case "1": layout = .single; return true
        case "2": layout = .spread; return true
        case "3": layout = .pair; return true
        case "4": layout = .grid; return true
        case "+", "=": zoomStep(1.25); return true
        case "-", "_": zoomStep(1 / 1.25); return true
        case "0": zoomToFit(); return true
        case "t", "T": showsTranscript.toggle(); return true
        default: return false
        }
    }

    func step(_ delta: Int) {
        guard let next = neighbour(delta) else { return }
        go(to: next)
    }

    private func availablePages(in folder: BookFolder) -> [Int] {
        guard let record = book else { return [] }
        let found = books.recentPages(limit: 500)
            .filter { $0.page.folder == folder }
            .map { record.humanPage($0.page.number) }
        return Array(Set(found)).sorted()
    }

    private func ref(for human: Int) -> PageRef? {
        guard let book, let folder,
              let id = PageID(surface: folder.surface, page: human + book.firstPage - 1)
        else { return nil }
        return PageRef(folder: folder, page: id)
    }

    private func loadIfNeeded(_ human: Int) {
        guard strokes[human] == nil, let ref = ref(for: human) else { return }
        let raw = RawReader.strokes(at: books.rawFile(for: ref), page: ref.page)
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
    public func receive(page id: PageID, dot: DotSample, event: DotEvent) {
        // Live dots carry a surface identity, not a copy, so the copy is the one being written in
        // now — which is the same decision the router has already taken for the stored strokes.
        let record = books.record(for: id)
        let human = record?.humanPage(id.page) ?? id.page
        activeBook = record?.folder.name
        activePage = human
        // Only follow the pen if you asked to. Writing in another notebook while you are reading
        // this one should not pull the window out from under you.
        if following {
            if let live = record?.folder, live != folder { show(page: PageRef(folder: live, page: id)) }
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
    /// Where the paper was when this drag started. A drag reports how far it has come, not where
    /// it is, so the pan it produces has to be added to something.
    @State private var panBase: CGSize?
    @State private var hovering = false
    @State private var gripping = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sheets
                if viewer.showsTranscript {
                    Divider()
                    TranscriptPane(viewer: viewer)
                        .frame(width: Viewer.transcriptWidth)
                }
            }
            bar
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            viewer.refreshTranscript()
        }
    }

    private var sheets: some View {
        GeometryReader { geo in
            let shape = viewer.layout.shape
            // Zoom multiplies the paper and the space between sheets alike, so a spread stays a
            // spread as it grows. The sheet is drawn at a zoomed size rather than only scaled
            // up, so the ink is sharp — but at the size the zoom last came to rest at. While it
            // is moving, that drawing is stretched the rest of the way, and redrawn when it stops.
            let sheet = viewer.fittedSheet(in: geo.size)
            let size = CGSize(width: sheet.width * viewer.drawnZoom, height: sheet.height * viewer.drawnZoom)
            let gap = Viewer.gap * viewer.drawnZoom
            let slots = viewer.visible

            VStack(spacing: gap) {
                ForEach(0..<shape.rows, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<shape.columns, id: \.self) { column in
                            let index = row * shape.columns + column
                            if index < slots.count, let page = slots[index] {
                                Sheet(viewer: viewer, page: page, size: size)
                            } else {
                                // The inside cover, or past the end. The gap is the sheet that
                                // is not there.
                                Color.clear.frame(width: size.width, height: size.height)
                            }
                        }
                    }
                }
            }
            // About its own middle, which is the middle of the window: the same place the
            // sheets would be if they had been drawn at this zoom.
            .scaleEffect(viewer.zoom / viewer.drawnZoom)
            .frame(width: geo.size.width, height: geo.size.height)
            .offset(x: viewer.pan.width, y: viewer.pan.height)
            .clipped()
            .contentShape(Rectangle())
            // Dragging only means something once there is more paper than window. Below that the
            // sheets keep their own gestures, so a double-click still lands on the sheet.
            .gesture(drag, including: viewer.canZoomOut ? .all : .subviews)
            // An open hand while there is paper to push. It is the only thing on screen that
            // says the page can be dragged, and nothing else is going to say it.
            .onHover { grip(on: $0 && viewer.canZoomOut) }
            .onChange(of: viewer.canZoomOut) { grip(on: $0 && hovering) }
            .onDisappear { grip(on: false) }
            .onAppear { viewer.setViewport(geo.size) }
            .onChange(of: geo.size) { viewer.setViewport($0) }
            .onChange(of: viewer.layout) { _ in viewer.setViewport(geo.size) }
        }
    }

    /// Push and pop exactly once each. An unbalanced push leaves the hand on screen over every
    /// other window until something else happens to set a cursor.
    private func grip(on: Bool) {
        if on != hovering { hovering = on }
        guard on != gripping else { return }
        gripping = on
        if on { NSCursor.openHand.push() } else { NSCursor.pop() }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                let base = panBase ?? viewer.pan
                panBase = base
                viewer.setPan(CGSize(width: base.width + value.translation.width,
                                     height: base.height + value.translation.height))
            }
            .onEnded { _ in panBase = nil }
    }

    /// Every glyph in the bar, at the size of the text beside it. Left at the default they come
    /// out at 13 against 11pt labels, which is a different weight and a different optical centre
    /// — and a row of things that each centre themselves slightly differently reads as crooked.
    private static let glyph = Font.system(size: 11)

    private var bar: some View {
        // One height for the row, so each control centres inside the same box rather than each
        // inside its own.
        HStack(spacing: 10) {
            Text(viewer.title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 8)

            Button { viewer.step(-1) } label: { Image(systemName: "chevron.left").font(Self.glyph) }
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

            Button { viewer.step(1) } label: { Image(systemName: "chevron.right").font(Self.glyph) }
                .buttonStyle(.borderless)
                .disabled(!viewer.canStep.forward)

            Spacer(minLength: 8)

            // Always there, even at 100%. It used to appear only once you had zoomed in, which
            // meant the toolbar grew a control under your pointer at the moment you were using
            // the pointer — everything to the right of it jumped sideways. A number that is
            // always present costs four characters and moves nothing.
            //
            // Fixed width, because 100 and 800 are the same four characters but 25 is not.
            Text("\(Int((viewer.zoom * 100).rounded()))%")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(viewer.canZoomOut ? .primary : .secondary)
                .frame(width: 36, alignment: .trailing)

            // The way back out, as a glyph rather than as the number doing double duty. Disabled
            // rather than hidden at fit, so it keeps its place in the row.
            Button(action: viewer.zoomToFit) {
                Image(systemName: "arrow.counterclockwise").font(Self.glyph)
            }
            .buttonStyle(.borderless)
            .disabled(!viewer.canZoomOut)
            .help("The whole page again (⌘0). ⌘+ and ⌘− zoom in and out.")

            // The text beside the ink. Lit while it is open, like any toggle in a toolbar.
            Button { viewer.showsTranscript.toggle() } label: {
                Image(systemName: "text.alignleft").font(Self.glyph)
                    .foregroundStyle(viewer.showsTranscript ? Ink.accent : Color.primary)
            }
            .buttonStyle(.borderless)
            .help("Show the transcript of this page (T)")

            Picker("", selection: $viewer.layout) {
                ForEach(ViewerLayout.allCases) { option in
                    Image(systemName: option.symbol).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
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
        .frame(height: 22)
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

/// The page as text, beside the page as ink.
///
/// The text is somebody else's reading of the handwriting, made from the picture in the bucket.
/// It is shown as it was written — headings, lists, the marks for a word that could not be read —
/// and nothing here edits it.
private struct TranscriptPane: View {
    @ObservedObject var viewer: Viewer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Transcript")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if viewer.fetchingTranscript {
                    ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12, height: 12)
                }
                Spacer(minLength: 0)
                if case let .text(text) = viewer.transcript {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the transcript")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    switch viewer.transcript {
                    case let .text(text):
                        ForEach(Array(Self.lines(of: text).enumerated()), id: \.offset) { _, line in
                            row(line)
                        }
                    case .none:
                        note("No transcript for this page yet.")
                    case let .unavailable(why):
                        note(why)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    enum Line: Equatable {
        case title(String)
        case heading(String)
        case body(String)
        case blank
    }

    /// Markdown, a line at a time. Only what a transcript uses: a title, the headings that say
    /// when a part was written, and lines of text with their emphasis and their crossings-out.
    /// A full renderer would reflow the lines, and the line breaks are the handwriting's own.
    static func lines(of text: String) -> [Line] {
        text.components(separatedBy: "\n").map { raw in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.hasPrefix("## ") { return .heading(String(line.dropFirst(3))) }
            if line.hasPrefix("# ") { return .title(String(line.dropFirst(2))) }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return .blank }
            return .body(line)
        }
    }

    @ViewBuilder private func row(_ line: Line) -> some View {
        switch line {
        case let .title(text):
            Text(text).font(.system(size: 13, weight: .semibold)).padding(.bottom, 2)
        case let .heading(text):
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.top, 10).padding(.bottom, 1)
        case let .body(text):
            Text(Self.inline(text)).font(.system(size: 13)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .blank:
            Color.clear.frame(height: 5)
        }
    }

    /// Emphasis and strike-through inside one line, with its indentation kept, and a list
    /// marker drawn as the bullet it stands for.
    static func inline(_ line: String) -> AttributedString {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        var rest = String(line.dropFirst(indent.count))
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") { rest = "• " + rest.dropFirst(2) }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: rest, options: options)) ?? AttributedString(rest)
        return AttributedString(String(indent).replacingOccurrences(of: " ", with: "\u{00A0}")) + parsed
    }
}

/// One sheet of paper at its real proportions, with the ink that is on it.
private struct Sheet: View {
    @ObservedObject var viewer: Viewer
    let page: Int
    /// How big this sheet is drawn, zoom included. The ink is laid out to it, so zooming in
    /// redraws the strokes rather than magnifying pixels.
    let size: CGSize

    private var isActive: Bool { viewer.activeIsHere && viewer.activePage == page }

    var body: some View {
        let g = viewer.geometry
        let scale = size.width / g.widthCells

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

/// Resizable, and floating so it survives being presented over.
///
/// The window is a window: any shape you like. It used to be locked to the paper's proportions,
/// which meant every window you widened also grew taller, half a screen went to a shape you did
/// not choose, and opening a spread resized the window under you. The paper keeps its own shape
/// inside whatever window you make, and zoom is how you get closer to it.
public final class ViewerWindowController: NSWindowController {
    private let viewer: Viewer
    /// The window keeps whatever size you give it, but it has to start somewhere sensible.
    private var hasSized = false
    /// The bar along the bottom, which is not paper: a wheel over it is a wheel over a toolbar.
    private static let barHeight: CGFloat = 31
    private var wheel: Any?

    public init(viewer: Viewer) {
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
        // The pane is added to the window, not carved out of the paper: the page stays the size
        // it was, and the window grows to the right as far as the screen lets it.
        viewer.onTranscriptToggle = { [weak self] shown in
            guard let window = self?.window else { return }
            var frame = window.frame
            frame.size.width += shown ? Viewer.transcriptWidth : -Viewer.transcriptWidth
            frame.size.width = max(frame.size.width, window.minSize.width)
            if let visible = window.screen?.visibleFrame {
                frame.size.width = min(frame.size.width, visible.width)
                frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.size.width))
            }
            window.setFrame(frame, display: true, animate: true)
        }
        // Wheel and pinch do not reach SwiftUI on macOS 13, and a view that catches them would
        // have to sit over the sheets and swallow their clicks. A monitor sees them first and
        // hands back anything that is not ours.
        wheel = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) {
            [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.gesture(event) ? nil : event
        }
    }

    deinit { if let wheel { NSEvent.removeMonitor(wheel) } }

    /// Scroll zooms, pinch zooms, and the paper moves by dragging it. Two gestures, no modifier
    /// key, nothing that needs a keyboard — this is a window for looking at a page, not a
    /// document you scroll through, and a page you are zoomed into is a thing you push around
    /// with your hand.
    private func gesture(_ event: NSEvent) -> Bool {
        guard let window, let anchor = anchor(of: event, in: window) else { return false }
        switch event.type {
        case .magnify:
            viewer.zoomBy(1 + Double(event.magnification), about: anchor)
            return true
        case .scrollWheel:
            // Exponential in both cases, so a given movement is the same proportion of a change
            // whether you are at 100% or at 600%.
            if event.hasPreciseScrollingDeltas {
                // A trackpad keeps sending events after the fingers lift, to coast a scroll to
                // a stop. A zoom that carries on by itself is a zoom you then have to undo, so
                // those are taken and dropped.
                guard event.momentumPhase.isEmpty else { return true }
                let dy = Double(event.scrollingDeltaY)
                guard dy != 0 else { return true }
                viewer.zoomBy(exp(dy * 0.006), about: anchor)
            } else {
                // A mouse wheel reports lines, and an accelerated flick reports a dozen of them
                // in one event, which used to be a jump of several hundred percent. One event is
                // held to a small step; a longer roll is simply more events.
                let lines = max(-2, min(2, Double(event.scrollingDeltaY)))
                guard lines != 0 else { return true }
                viewer.zoomBy(exp(lines * 0.08), about: anchor)
            }
            return true
        default:
            return false
        }
    }

    /// Where the pointer is over the sheets, measured from their top left — nil when it is over
    /// the bar, or outside. Taken from the window rather than from a view so that it does not
    /// depend on which way up the hosted view happens to be.
    private func anchor(of event: NSEvent, in window: NSWindow) -> CGPoint? {
        let rect = window.contentLayoutRect
        let point = event.locationInWindow
        // The transcript is text, and a wheel over text scrolls it.
        let paper = rect.maxX - (viewer.showsTranscript ? Viewer.transcriptWidth : 0)
        guard point.y >= rect.minY + Self.barHeight, point.y <= rect.maxY,
              point.x >= rect.minX, point.x <= paper else { return nil }
        return CGPoint(x: point.x - rect.minX, y: rect.maxY - point.y)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func key(_ key: String) -> Bool {
        switch key {
        case "\u{F702}": viewer.step(-1)          // left arrow
        case "\u{F703}": viewer.step(1)           // right arrow
        default: return viewer.handle(key: key)
        }
        return true
    }

    /// Open at the shape of the paper — once.
    ///
    /// The first time there is nothing to take a size from, so it is taken from the screen and
    /// from the notebook: a document window that appears at 240 points on a 2000 point display is
    /// not a choice anybody made. From then on the size is yours and nothing touches it.
    private func sizeToPaper() {
        guard let window else { return }
        let paper = viewer.aspect
        guard paper > 0 else { return }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Height carries the bar as well as the sheet, so the paper's ratio is adjusted for it.
        var height = max(window.minSize.height, min(visible.height * 0.82, 940))
        var width = (height - Self.barHeight) * paper

        // A spread on a narrow screen would otherwise run off both sides.
        let maxWidth = visible.width * 0.92
        if width > maxWidth {
            width = maxWidth
            height = width / paper + Self.barHeight
        }

        window.setContentSize(NSSize(width: width, height: height))
        window.center()
    }

    public override func showWindow(_ sender: Any?) {
        let first = !hasSized
        hasSized = true
        super.showWindow(sender)
        window?.title = viewer.title
        if first { sizeToPaper() }
    }

    /// The window is named for the notebook in it, not for the app.
    public func retitle() { window?.title = viewer.title }
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

    /// ⌘+, ⌘− and ⌘0, as in every window that shows a page.
    ///
    /// By the key as well as by the character it types: on a Czech keyboard the key that says 0
    /// types "é" unless Shift is held, and ⌘0 is still the key somebody presses.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, flags.contains(.command),
           !flags.contains(.control), !flags.contains(.option) {
            let typed = event.charactersIgnoringModifiers ?? ""
            let key: String?
            switch (event.keyCode, typed) {
            case (24, _), (69, _), (_, "+"), (_, "="): key = "+"     // the = key, keypad +
            case (27, _), (78, _), (_, "-"), (_, "_"): key = "-"     // the - key, keypad -
            case (29, _), (82, _), (_, "0"): key = "0"               // the 0 key, keypad 0
            default: key = nil
            }
            if let key, onKey?(key) == true { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}
