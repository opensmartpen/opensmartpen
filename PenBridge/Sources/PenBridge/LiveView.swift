import AppKit
import PenBridgeCore
import SwiftUI

/// The page you are writing on, drawn as you write it.
///
/// Two sources feed it. Ink already on the sheet is read once from the raw file, so opening the
/// window halfway down a page shows what is above your pen rather than a blank sheet. Everything
/// after that arrives dot by dot from `PenSession.onDot`, ahead of stroke assembly — a stroke is
/// only finished on pen-up, and waiting for that would make writing appear a word at a time.
final class LiveCanvas: ObservableObject {
    /// Finished strokes, oldest first.
    @Published private(set) var strokes: [[CGPoint]] = []
    /// The stroke currently under the pen.
    @Published private(set) var inProgress: [CGPoint] = []
    @Published private(set) var page: PageID?
    @Published private(set) var title = "Waiting for the pen"
    @Published private(set) var geometry: PageGeometry = .a4

    private let books: BookRegistry
    /// Dots land at up to ~120/s. Publishing every one would redraw far more often than the
    /// display can show, so the in-progress stroke is flushed on a display-rate timer instead.
    private var pendingDots: [CGPoint] = []
    private var flushScheduled = false

    init(books: BookRegistry) {
        self.books = books
    }

    /// Switch to a page, loading whatever is already written on it.
    func show(_ page: PageID) {
        guard page != self.page else { return }
        self.page = page
        let label = books.label(for: page)
        title = label.oneLine
        geometry = books.record(for: page)?.geometry ?? .a4
        strokes = RawReader.strokes(at: books.rawFile(for: page)).map { stroke in
            stroke.dots.map { CGPoint(x: $0.x, y: $0.y) }
        }
        inProgress = []
        pendingDots = []
    }

    /// One dot from the pen, straight off the wire.
    func receive(page: PageID, dot: DotSample, event: DotEvent) {
        // Turning to a new sheet retargets the window; that is the behaviour you want when the
        // point of it is to follow your hand.
        if page != self.page { show(page) }

        switch event {
        case .down:
            commitPending()
            if !inProgress.isEmpty { strokes.append(inProgress) }
            inProgress = [CGPoint(x: dot.x, y: dot.y)]
        case .move:
            pendingDots.append(CGPoint(x: dot.x, y: dot.y))
            scheduleFlush()
        case .up:
            commitPending()
            inProgress.append(CGPoint(x: dot.x, y: dot.y))
            strokes.append(inProgress)
            inProgress = []
        }
    }

    func clearForDisconnect() {
        commitPending()
        if !inProgress.isEmpty {
            strokes.append(inProgress)
            inProgress = []
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            self?.flushScheduled = false
            self?.commitPending()
        }
    }

    private func commitPending() {
        guard !pendingDots.isEmpty else { return }
        inProgress.append(contentsOf: pendingDots)
        pendingDots = []
    }
}

struct LivePage: View {
    @ObservedObject var canvas: LiveCanvas

    var body: some View {
        VStack(spacing: 0) {
            Canvas { context, size in
                // Ncode cells map onto the sheet directly; one scale for both axes keeps the
                // handwriting's proportions, and the page is letterboxed inside the window.
                let scale = min(size.width / canvas.geometry.widthCells,
                                size.height / canvas.geometry.heightCells)
                let sheet = CGSize(width: canvas.geometry.widthCells * scale,
                                   height: canvas.geometry.heightCells * scale)
                let origin = CGPoint(x: (size.width - sheet.width) / 2,
                                     y: (size.height - sheet.height) / 2)

                context.fill(Path(CGRect(origin: origin, size: sheet)), with: .color(.white))

                var ink = context
                ink.translateBy(x: origin.x, y: origin.y)
                ink.clip(to: Path(CGRect(origin: .zero, size: sheet)))

                for stroke in canvas.strokes {
                    draw(stroke, in: &ink, scale: scale, colour: .black)
                }
                // The stroke under the pen is drawn in ink too — it is writing, not a preview.
                draw(canvas.inProgress, in: &ink, scale: scale, colour: .black)
            }
            .background(Color(nsColor: .windowBackgroundColor))

            HStack {
                Text(canvas.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(canvas.strokes.count) strokes")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial)
        }
    }

    /// A dot is a position, not a segment, so a single tap would otherwise draw nothing.
    private func draw(_ points: [CGPoint], in context: inout GraphicsContext,
                      scale: Double, colour: Color) {
        guard let first = points.first else { return }
        if points.count == 1 {
            let r = 0.45 * scale
            context.fill(Path(ellipseIn: CGRect(x: first.x * scale - r, y: first.y * scale - r,
                                                width: r * 2, height: r * 2)),
                         with: .color(colour))
            return
        }
        var path = Path()
        path.move(to: CGPoint(x: first.x * scale, y: first.y * scale))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * scale, y: point.y * scale))
        }
        context.stroke(path, with: .color(colour),
                       style: StrokeStyle(lineWidth: max(1, 0.55 * scale),
                                          lineCap: .round, lineJoin: .round))
    }
}

/// Plain resizable window, floating so it survives being screen-shared over.
final class LiveWindowController: NSWindowController {
    convenience init(canvas: LiveCanvas) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Live page"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(rootView: LivePage(canvas: canvas))
        // Above ordinary windows so it stays visible while you present from another app, but not
        // above everything: a screen-sharing toolbar should still be reachable.
        window.level = .floating
        window.collectionBehavior = [.managed, .fullScreenAuxiliary]
        self.init(window: window)
    }
}
