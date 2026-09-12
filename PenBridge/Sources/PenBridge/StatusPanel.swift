import AppKit
import PenBridgeCore
import SwiftUI

/// Violet ink. The resting state carries no colour at all — ink on paper is the "everything is
/// fine" signal — so the accent only appears on work in flight, and red only when something wants
/// fixing. No green anywhere: this is a pen, not a router.
enum Ink {
    static let accent = Color(nsColor: dynamic(light: NSColor(srgbRed: 0.357, green: 0.247, blue: 0.769, alpha: 1),
                                               dark: NSColor(srgbRed: 0.655, green: 0.592, blue: 0.941, alpha: 1)))
    static let critical = Color(nsColor: dynamic(light: NSColor(srgbRed: 0.651, green: 0.227, blue: 0.196, alpha: 1),
                                                 dark: NSColor(srgbRed: 0.886, green: 0.478, blue: 0.439, alpha: 1)))

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
}

/// The panel says each thing once. A page's countdown is the only place its timing appears, the
/// battery is a number in the header rather than a labelled gauge, and nothing the header has
/// already said is repeated underneath it. Prose survives in exactly two states — a failure and a
/// first run — because those are the only ones where the next move is not obvious.
struct StatusPanel: View {
    @ObservedObject var model: PanelModel
    /// Ticks while the panel is open so the countdowns move.
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !model.pending.isEmpty { section { pending } }
            if case let .failing(_, _, error) = model.status { section { failure(error) } }
            if case let .copying(_, _, percent) = model.status { section { copying(percent) } }
            if let question = model.instanceQuestion { section { newNotebook(question) } }
            if model.showsWakeHint { section { wakeHint } }
            if !model.pens.isEmpty { section { penRow } }
            if !model.recent.isEmpty { section { recent } }
            footer
        }
        .frame(width: 300)
    }

    // MARK: header — state, freshness and battery on one line

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(dotColour)
                .frame(width: 7, height: 7)
            Text(headline)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            if let meta = headerMeta {
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            PinButton(pinned: model.isPinned, action: model.togglePin)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
    }

    private var dotColour: Color {
        switch model.status {
        case .failing: return Ink.critical
        case .copying, .writing: return Ink.accent
        case .asleep, .bluetoothOff, .connecting: return Color.secondary.opacity(0.45)
        case .connected: return Color.primary
        }
    }

    private var headline: String {
        switch model.status {
        case .asleep: return "Pen off"
        case .bluetoothOff: return "Bluetooth off"
        case .connecting: return "Connecting"
        // One word for the whole journey. Pen-to-Mac and Mac-to-git are different legs of it, and
        // nobody watching a panel cares which leg — only whether the writing arrived.
        case let .copying(book, count, _): return count > 1 ? "Syncing \(book) of \(count)" : "Syncing"
        case .failing: return "Can't sync"
        case .writing: return "Writing"
        case .connected: return model.pending.isEmpty ? "All synced" : "Waiting to sync"
        }
    }

    /// How long the pen has been away, and only that.
    ///
    /// Time since the last sync used to live here too, and it earned nothing: when the headline
    /// already says "All synced", the age of that sync answers a question nobody asked — and if it
    /// is old with nothing pending, that only means you have not written, which the recent list
    /// says better. A pen that has not been seen for days is different: it may be holding pages,
    /// and nothing on this Mac can count them.
    private var headerMeta: String? {
        guard case .asleep = model.status, let seen = model.lastSeen,
              now.timeIntervalSince(seen) > Self.staleAfter else { return nil }
        return "seen \(Self.brief(since: seen, now: now))"
    }

    /// A pen unseen for longer than this is worth mentioning. Shorter than this is an ordinary day.
    private static let staleAfter: TimeInterval = 36 * 3600

    // MARK: pending — one row per page, the countdown doing all the talking

    private var pending: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.pending.prefix(5)) { row in
                HStack(spacing: 7) {
                    Circle()
                        .fill(row.isLive ? Ink.accent : Color.clear)
                        .frame(width: 5, height: 5)
                    Text(row.label.oneLine)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 6)
                    if let deadline = row.deadline {
                        Text(Self.clock(to: deadline, from: now))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
            if model.pending.count > 5 {
                Text("+\(model.pending.count - 5)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            // Quiet on purpose. Syncing happens on its own once you stop writing; this is only
            // here for the moment you are closing the lid and do not want to wait out the
            // countdown. A filled primary button would imply the app needs you, and it does not.
            Button(model.isPublishing ? "Syncing…" : "Sync now", action: model.publishNow)
                .buttonStyle(QuietButtonStyle())
                .disabled(model.isPublishing)
                .padding(.top, 3)
        }
    }

    // MARK: recent — click to open the rendered page

    private var recent: some View {
        // No heading. The hairline above already says a new thing starts here, and a notebook
        // with its own mark beside it does not need to be announced as recent.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.recent) { book in
                RecentRow(book: book) { model.open(book) }
            }
        }
    }

    // MARK: pens — who is writing, and how charged they are

    /// Always tiles, whether there is one pen or three. A tile keeps its own width rather than
    /// stretching, so a single pen is a single tile at the left rather than a box across the panel.
    private var penRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(model.pens) { pen in
                    PenTile(pen: pen, open: model.expandedPen == pen.id) {
                        model.toggleExpanded(pen.id)
                    }
                }
                Spacer(minLength: 0)
            }
            if let pen = model.expanded {
                inkRow(for: pen).padding(.top, 11)
            }
        }
    }

    // MARK: ink — two rows of glyphs, and one sentence only when it is needed

    /// What the next stroke will be drawn as. No labels: a swatch says "red" better than the word
    /// does, and the panel cannot afford the line. The one exception is an ink with no measured
    /// colour behind it, where the consequence — the page renders black — is otherwise invisible
    /// until somebody opens a PNG days later.
    private func inkRow(for pen: PanelModel.PenRow) -> some View {
        let ink = pen.active ? model.ink : pen.ink
        let width = pen.active ? model.width : pen.width
        return HStack(spacing: 10) {
            // One click, and no furniture. Unchosen inks drop back; the chosen one is full
            // strength with a thin ring around it — the least that can be drawn and still be
            // unambiguous, and the fewest clicks to change what you are writing with.
            HStack(spacing: 7) {
                ForEach(model.inks, id: \.rawValue) { colour in
                    InkDot(colour: Color(inkHex: model.palette.hex(for: colour)) ?? .primary,
                           selected: colour == ink) { model.choose(ink: colour, for: pen) }
                        .help(colour.rawValue.capitalized)
                }
            }

            Spacer(minLength: 0)

            // Width stays a segmented control: three shapes you compare against each other, which
            // is exactly what a segmented control is for and what a pop-up would hide.
            Picker("", selection: Binding(
                get: { width },
                set: { model.choose(width: $0, for: pen) })) {
                    // "Default" is not a button on the strip — it is the state before anything is
                    // tapped — so it is not one here either.
                    ForEach([LineWidth.thin, .medium, .thick], id: \.rawValue) { weight in
                        Image(nsImage: Swatches.bar(weight)).tag(weight)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
        }
    }

    // MARK: the two states that still need words

    private func failure(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(error)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            // The one line that matters: nothing has been lost.
            Text("\(model.pending.count) page\(model.pending.count == 1 ? "" : "s") safe on disk.")
                .font(.system(size: 11.5, weight: .medium))
            HStack(spacing: 7) {
                Button("Retry", action: model.publishNow)
                    .buttonStyle(InkButtonStyle(filled: true))
                Button("Log", action: model.openLog)
                    .buttonStyle(InkButtonStyle(filled: false))
            }
        }
    }

    /// The one question the panel ever asks. It has to be asked, because two notebooks of the same
    /// model are indistinguishable to the pen and guessing wrong merges them silently.
    private func newNotebook(_ question: PanelModel.InstanceQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Is this a new \(question.title)?")
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(question.why)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 7) {
                Button("Yes, it's new", action: model.confirmNewNotebook)
                    .buttonStyle(InkButtonStyle(filled: true))
                Button("Same one", action: model.dismissNewNotebook)
                    .buttonStyle(InkButtonStyle(filled: false))
            }
        }
    }

    private var wakeHint: some View {
        Text("Press the pen's button to wake it, and keep it near this Mac.")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func copying(_ percent: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Bar(fraction: Double(percent) / 100, tint: Ink.accent)
            if let pages = model.pagesOnPen {
                Text("\(pages) page\(pages == 1 ? "" : "s") left on the pen")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: chrome

    /// Menu items, because that is what they are. A row of equal-width tabs implied four peers of
    /// the same kind; these are two places to go and two things to do, and macOS already has a
    /// shape for that.
    private var footer: some View {
        VStack(spacing: 0) {
            hairline
            VStack(spacing: 1) {
                // Nothing here for opening a notebook: clicking one in the list above already
                // does that, and "Reveal notes" is a folder you rarely want and can reach from
                // Settings. What is left is what a menubar app's menu is actually for.
                MenuItem(title: "Settings…", shortcut: "⌘,", action: model.openConfig)
                MenuItem(title: "Quit PenBridge", shortcut: "⌘Q") { NSApp.terminate(nil) }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
        }
    }

    /// Every section is a hairline plus the same padding, so the layout does not repeat either.
    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            hairline
            content()
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
        }
    }

    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
    }

    // MARK: formatting

    /// "6:12" — the wait, with no word wrapped around it.
    static func clock(to deadline: Date, from now: Date) -> String {
        let remaining = Int(deadline.timeIntervalSince(now).rounded(.up))
        guard remaining > 0 else { return "now" }
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    /// "4m", "2h", "3d" — freshness in the space of a word.
    static func brief(since date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}

// MARK: - pieces

/// A notebook, not a page. What you reach for is the book; the viewer decides which page it falls
/// open at, and it always falls open at the last one you wrote.
private struct RecentRow: View {
    let book: PanelModel.RecentBook
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                // Leading, like the status dot in the header: a mark at the start of a line reads
                // as "this one", and the same mark in the same place means the same thing twice.
                // Always laid out, so the titles line up whether or not it is drawn.
                Circle()
                    .fill(book.latest ? Ink.accent : Color.clear)
                    .frame(width: 5, height: 5)
                PaperMark(shape: book.shape, binding: book.binding)
                Text(book.title)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(hovering ? Color.primary.opacity(0.07) : Color.clear))
        .onHover { hovering = $0 }
    }
}

/// The pen, drawn in its own ink. A highlighter is a band rather than a nib, because that is what
/// it makes.
/// The same outline pencil the menubar draws, on the grid it was authored on. Bare rather than
/// boxed: a filled square around a 15-point glyph is mostly square, and the tile itself is already
/// the thing that can be filled.
private struct Pencil: View {
    let colour: Color
    let size: CGFloat

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 16
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
            var body = Path()
            body.move(to: p(11.2, 1.6))
            body.addLine(to: p(14.4, 4.8))
            body.addLine(to: p(5.6, 13.6))
            body.addLine(to: p(1.9, 14.5))
            body.addLine(to: p(2.8, 10.8))
            body.closeSubpath()
            var ferrule = Path()
            ferrule.move(to: p(9.6, 3.2))
            ferrule.addLine(to: p(12.8, 6.4))
            for path in [body, ferrule] {
                context.stroke(path, with: .color(colour),
                               style: StrokeStyle(lineWidth: 1.4 * scale,
                                                  lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

/// One ink. A ring rather than a card or a well: it is the smallest mark that separates chosen
/// from not, and it leaves the colour itself untouched.
private struct InkDot: View {
    let colour: Color
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            Circle()
                .fill(colour)
                .frame(width: 12, height: 12)
                .opacity(selected ? 1 : hovering ? 0.75 : 0.4)
                .overlay(Circle()
                    .stroke(Color.primary.opacity(selected ? 0.45 : 0), lineWidth: 1)
                    .padding(-2.5))
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct BatteryBar: View {
    let percent: Int
    let low: Bool
    /// Set when the bar sits on a tile filled with ink, where the usual greys disappear.
    var onInk: Color?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill((onInk ?? Color.primary).opacity(onInk == nil ? 0.14 : 0.3))
                Capsule().fill(low ? Ink.critical : (onInk ?? Color.secondary))
                    .frame(width: max(2, geo.size.width * CGFloat(percent) / 100))
            }
        }
        .frame(height: 3)
    }
}

/// One pen. Open, the tile fills with that pen's own ink — which is both the selection and the
/// answer to "what does this pen write in". Closed, it shows its battery instead, because a tile
/// you are not using has nothing else worth saying.
///
/// Which pen is in your hand is reported, never chosen: a click that "selected" a pen would be a
/// second and disagreeing answer to a question the hardware already settled.
private struct PenTile: View {
    let pen: PanelModel.PenRow
    let open: Bool
    let tap: () -> Void
    @State private var hovering = false

    /// Filled when this is the pen you are using, or the one you have opened.
    private var filled: Bool { pen.active || open }

    private var inkColour: Color {
        Color(inkHex: Palette.hexForPreview(pen.ink)) ?? .primary
    }

    /// What reads on top of the ink when the tile is filled.
    private var onInk: Color {
        pen.ink == .yellow || pen.ink == .white ? .black : .white
    }

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 3) {
                Pencil(colour: filled ? onInk : inkColour, size: 16)
                HStack(spacing: 3) {
                    if pen.active {
                        Circle().fill(filled ? onInk : Ink.accent).frame(width: 4, height: 4)
                    }
                    Text(pen.name)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(filled ? onInk : Color.primary)
                        .lineLimit(1)
                }
                if let percent = pen.percent {
                    BatteryBar(percent: percent, low: pen.low, onInk: filled ? onInk : nil)
                } else {
                    Color.clear.frame(height: 3)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(width: 78)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(filled ? inkColour : hovering ? Color.primary.opacity(0.07) : Color.clear))
            // A black pen filled with black ink would vanish into a dark panel, so a filled tile
            // always carries a hairline.
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(filled ? 0.16 : 0), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(pen.percent.map { "\(pen.name) · \($0)%" } ?? pen.name)
    }
}

/// Images for the segmented controls.
///
/// An ink is a real colour and must not be tinted by the system, so it is a plain image. A line
/// weight is not a colour — it is a shape — so it is a template and macOS colours it to match the
/// selection, which is exactly the behaviour in a native picker.
enum Swatches {
    static func dot(_ hex: String?) -> NSImage {
        let side: CGFloat = 15
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let colour = NSColor(hex: hex) ?? .labelColor
            colour.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: side - 2, height: side - 2)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    static func bar(_ weight: LineWidth) -> NSImage {
        let height: CGFloat
        switch weight {
        case .thin: height = 1
        case .default, .medium: height = 3
        case .thick: height = 6
        }
        let size = NSSize(width: 17, height: 8)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: (size.height - height) / 2,
                                      width: size.width, height: height)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

private extension NSColor {
    convenience init?(hex: String?) {
        guard var h = hex else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                  green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

private extension Color {
    /// Nil for an unmeasured ink, so the caller decides what absence means rather than being
    /// handed a silent black.
    init?(hex: String?) {
        guard var h = hex else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255)
    }
}

/// The paper itself, in its real proportions — and drawn as the object it is. A pad is a loose
/// sheet; a bound notebook gets the elastic band across it, which is how you tell the two apart on
/// a desk without reading anything.
///
/// Nothing here is invented: the proportions come from the recorded paper size and the band from
/// the recorded binding.
private struct PaperMark: View {
    let shape: KnownBooks.Shape
    let binding: KnownBooks.Binding

    private var size: CGSize {
        switch shape {
        case .wide: return CGSize(width: 12, height: 8.5)
        case .page: return CGSize(width: 8.5, height: 11)
        case .pocket: return CGSize(width: 7.5, height: 11)
        }
    }

    var body: some View {
        Canvas { context, canvas in
            let origin = CGPoint(x: (canvas.width - size.width) / 2,
                                 y: (canvas.height - size.height) / 2)
            let body = CGRect(origin: origin, size: size)
            let ink = Color.secondary.opacity(0.65)

            context.stroke(Path(roundedRect: body, cornerRadius: 1.5),
                           with: .color(ink), lineWidth: 1)

            if binding == .bound {
                // The elastic, closer to the spine side than the middle, running off both edges
                // exactly as it does on the real thing.
                let x = body.minX + size.width * 0.72
                var band = Path()
                band.move(to: CGPoint(x: x, y: body.minY - 1))
                band.addLine(to: CGPoint(x: x, y: body.maxY + 1))
                context.stroke(band, with: .color(ink), lineWidth: 1)
            }
        }
        .frame(width: 14, height: 13)
    }
}

private struct Bar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.11))
                Capsule().fill(tint)
                    .frame(width: max(fraction > 0 ? 3 : 0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
    }
}

private struct InkButtonStyle: ButtonStyle {
    let filled: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(filled ? (isEnabled ? Ink.accent : Color.primary.opacity(0.10)) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(filled ? Color.clear : Color.primary.opacity(0.15)))
            .foregroundStyle(filled ? (isEnabled ? Color.white : Color.secondary) : Color.primary)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// A button for something the app will do anyway. It reads as available rather than as required.
private struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.5))
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// Keeping the panel on screen. In the corner rather than the footer: it acts on the window
/// itself, and the footer is for places to go.
private struct PinButton: View {
    let pinned: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 10.5))
                .rotationEffect(.degrees(45))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(pinned ? Ink.accent : hovering ? Color.secondary : Color.secondary.opacity(0.45))
        .onHover { hovering = $0 }
        .help(pinned ? "Unpin" : "Keep this panel open")
    }
}

private struct MenuItem: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12))
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(hovering ? Color.primary.opacity(0.08) : Color.clear))
        .onHover { hovering = $0 }
    }
}
