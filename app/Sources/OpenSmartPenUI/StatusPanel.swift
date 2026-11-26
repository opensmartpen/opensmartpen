import AppKit
import OpenSmartPenCore
import SwiftUI

/// Violet ink. The resting state carries no colour at all — ink on paper is the "everything is
/// fine" signal — so the accent only appears on work in flight, and red only when something wants
/// fixing. Green is for one thing: something that has been checked and works. Nowhere else —
/// this is a pen, not a router.
enum Ink {
    static let accent = Color(nsColor: dynamic(light: NSColor(srgbRed: 0.357, green: 0.247, blue: 0.769, alpha: 1),
                                               dark: NSColor(srgbRed: 0.655, green: 0.592, blue: 0.941, alpha: 1)))
    static let done = Color(nsColor: dynamic(light: NSColor(srgbRed: 0.192, green: 0.545, blue: 0.290, alpha: 1),
                                             dark: NSColor(srgbRed: 0.416, green: 0.780, blue: 0.470, alpha: 1)))
    static let critical = Color(nsColor: dynamic(light: NSColor(srgbRed: 0.651, green: 0.227, blue: 0.196, alpha: 1),
                                                 dark: NSColor(srgbRed: 0.886, green: 0.478, blue: 0.439, alpha: 1)))

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    /// An ink as the panel can actually draw it.
    ///
    /// Four of the five inks survive both appearances. Black does not survive dark: a 1.4pt
    /// stroke of #1C1C1E on a dark menu material is not a dark pen, it is an absent one. So no
    /// ink is drawn darker than the panel's own text in the dark appearance, nor lighter than it
    /// in the light one — an ink past that line is drawn at the text colour, and every other ink
    /// is untouched. Red, blue, green and yellow never cross it.
    ///
    /// The swatches in the ink row are exempt: they are a colour picker, and a picker that shows
    /// you white when you are choosing black has stopped being one.
    static func legible(_ colour: Color) -> Color {
        let base = NSColor(colour)
        return Color(nsColor: NSColor(name: nil) { appearance in
            guard let srgb = base.usingColorSpace(.sRGB) else { return base }
            let luminance = 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent
                + 0.114 * srgb.blueComponent
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if dark, luminance < 0.28 { return .labelColor }
            if !dark, luminance > 0.86 { return .labelColor }
            return base
        })
    }
}

/// The panel says each thing once. A page's countdown is the only place its timing appears, the
/// battery is a number in the header rather than a labelled gauge, and nothing the header has
/// already said is repeated underneath it. Prose survives in exactly two states — a failure and a
/// first run — because those are the only ones where the next move is not obvious.
public struct StatusPanel: View {
    @ObservedObject var model: PanelModel
    /// Ticks while the panel is open so the countdowns move.
    let now: Date

    public init(model: PanelModel, now: Date) {
        self.model = model
        self.now = now
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                // The pens come first and carry no rule above them: there is nothing above them
                // to be separated from. A headline used to sit here — a dot and a word for the
                // whole app — and it was saying a third time what the pen's own line and the
                // page countdowns already say, in a larger type size than either.
                if !model.pens.isEmpty {
                    penRow
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                    // With pens in the row, the reason none of them connects goes right under them.
                    if model.bluetoothRefused { section { bluetoothRefused } }
                }
                // What is left to set up, in the order that needs the least first: an agent,
                // then a first page, then a pen. Each step goes when it is done.
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    if index == 0, model.pens.isEmpty {
                        view(of: step).padding(.horizontal, 14).padding(.vertical, 11)
                    } else {
                        section { view(of: step) }
                    }
                }
                if !model.agents.isEmpty { section(inset: 5) { agents } }
                if case let .failing(_, _, error) = model.status { section { failure(error) } }
                if case let .copying(_, _, percent) = model.status { section { copying(percent) } }
                if !model.recent.isEmpty { section(inset: 5) { recent } }
                footer
            }
            // Over the panel rather than in a row of its own. It acts on the window, not on
            // anything the panel is showing, and a row for one 16-point glyph is a row wasted.
            PinButton(pinned: model.isPinned, action: model.togglePin)
                .padding(.top, 9)
                .padding(.trailing, 9)
        }
        // Wide enough for three pens and the pin, and no wider. The arithmetic, left to right:
        // 14 inset + three 64-point tiles + two 6-point gaps + 9 clear of the pin + the pin's own
        // 16 + its 9 from the edge. Three is the number to build for — it is as many pens as are
        // plausibly in use at once, and a panel sized for a hypothetical fourth is a panel that is
        // too wide every day for a case that never arrives. A fourth tile still fits the row; it
        // simply pushes under the pin, which is the right way round for something that rare.
        .frame(width: 252)
    }

    /// No pen has ever connected and there is no page: a person who is here for the first time
    /// and may not have a pen at all. The panel then leads with the one thing they can do.
    private enum Step { case agent, pen }

    /// The steps that are still to do: an agent, until one is connected; a pen, until one is added
    /// or the person skips it. The ideas come before the panel, in a window of their own.
    private var steps: [Step] {
        var out: [Step] = []
        if model.asksForAgent { out.append(.agent) }
        if model.pens.isEmpty, !model.skippedPen || model.isAddingPen || model.bluetoothRefused { out.append(.pen) }
        return out
    }

    /// A step has a number only while more than one is on screen.
    private func number(of step: Step) -> Int? {
        steps.count > 1 ? steps.firstIndex(of: step).map { $0 + 1 } : nil
    }

    /// One filled button in the panel at a time: the one of the first step that is left.
    private func leads(_ step: Step) -> Bool { steps.first == step }

    @ViewBuilder private func view(of step: Step) -> some View {
        switch step {
        case .agent: connectAgent
        case .pen: addYourPen
        }
    }

    /// "Skip", small and at the right: the way past a step that a person does not want now.
    private func skip(_ action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Skip", action: action)
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    private var startsWithoutAPen: Bool { model.pens.isEmpty && model.recent.isEmpty }

    /// The step for a Mac with no pen: a button. The app scans for no pen before the
    /// click, and macOS asks about Bluetooth at the click, when the person sees why. Without
    /// Bluetooth the button could do nothing, so the panel then says that in its place.
    @ViewBuilder private var addYourPen: some View {
        if model.bluetoothRefused {
            bluetoothRefused
        } else {
            VStack(alignment: .leading, spacing: 7) {
                stepTitle(number(of: .pen), "Add your pen")
                if model.isAddingPen {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 1) {
                            // With no pen in the row, this is the one place that can say it.
                            Text(model.status == .bluetoothOff ? "Bluetooth is off" : "Looking for your pen")
                                .font(.system(size: 11.5))
                            Text(model.status == .bluetoothOff ? "Turn on Bluetooth on this Mac."
                                 : "Switch it on, near this Mac.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(action: model.cancelAddingPen) { Text("Cancel").frame(maxWidth: .infinity) }
                        .buttonStyle(InkButtonStyle(filled: false))
                } else {
                    Button(action: model.addPen) { Text("Add Pen").frame(maxWidth: .infinity) }
                        .buttonStyle(InkButtonStyle(filled: leads(.pen)))
                    websiteLink("No pen yet?", "See pens that work", action: model.showPensThatWork)
                    skip(model.skipPen)
                }
            }
        }
    }

    // MARK: recent — click to open the rendered page

    private var recent: some View {
        // A heading, so that a short list of titles under a row of pens says what it is.
        VStack(alignment: .leading, spacing: 2) {
            Text("Notebooks")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 9)
                .padding(.bottom, 2)
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
                // The tile says which pen. This says everything else about it — and it is the
                // only place the charge appears as a number, which is why the open tile drops
                // its bar.
                // Not the name — the tile directly above already carries it, in that pen's own
                // ink. What the tile cannot say is whether the pen is awake, so that is what goes
                // here, with the charge on the other end of the same line.
                // Two figures on the right, each with its word: a bare "73%" was the charge to
                // anyone who knew, and the memory figure beside it would have made both a guess.
                HStack(spacing: 6) {
                    Text(pen.state)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let memory = pen.memory {
                        Text("Memory \(memory)%")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if pen.percent != nil {
                            Text("·").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                        }
                    }
                    if let percent = pen.percent {
                        Text("Battery \(percent)%")
                            .font(.system(size: 11.5))
                            .foregroundStyle(pen.low ? Ink.critical : Color.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.top, 10)
                inkRow(for: pen).padding(.top, 8)
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
            HStack(spacing: 4) {
                ForEach(model.inks, id: \.rawValue) { colour in
                    InkDot(colour: Color(inkHex: model.palette.hex(for: colour)) ?? .primary,
                           selected: colour == ink) { model.choose(ink: colour, for: pen) }
                        .help(colour.rawValue.capitalized)
                }
            }

            Spacer(minLength: 0)

            // Three marks, each drawn at the weight it sets. Not a segmented control: that draws
            // dividers between the three and a system-accent fill behind the chosen one, which
            // in a panel with almost no colour is the loudest thing on screen — and the marks
            // are already different enough from each other to compare at a glance.
            //
            // "Default" is not one of them. It is the state before anything has been tapped, not
            // a fourth weight you can ask for.
            HStack(spacing: 4) {
                ForEach([LineWidth.thin, .medium, .thick], id: \.rawValue) { weight in
                    WidthMark(weight: weight, selected: weight == width) {
                        model.choose(width: weight, for: pen)
                    }
                }
            }
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

    /// The name of a step, with its number in a small disc when the panel shows the steps in a row.
    private func stepTitle(_ number: Int?, _ title: String) -> some View {
        HStack(spacing: 6) {
            if let number {
                Text("\(number)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(Color.primary.opacity(0.12)))
            }
            Text(title).font(.system(size: 11.5, weight: .medium))
        }
    }

    /// Shown until an agent keeps a record. The app captures and stops; without an agent a page
    /// never becomes text, and nothing else in the panel would say why.
    private var connectAgent: some View {
        VStack(alignment: .leading, spacing: 7) {
            // The second step while the first is on screen above it. Alone, it has no number.
            stepTitle(number(of: .agent), "Connect your agent")
            // The link is at the end of the text, so it wraps with it. It goes through the model,
            // which also counts the click.
            (Text("Paste this into Claude Code, Codex or another agent. ").foregroundColor(.secondary)
             + Text(.init("[Learn more](\(PanelModel.agentsURL.absoluteString))")))
                .font(.system(size: 10.5))
                .tint(Ink.accent)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { _ in model.showAgentsThatWork(); return .handled })
            // One filled button in the panel at a time. While "Add Pen" is above, it is that one.
            Button(model.agentSentenceCopied ? "Copied" : "Copy instructions", action: model.copyAgentSentence)
                .buttonStyle(InkButtonStyle(filled: leads(.agent)))
        }
    }

    /// A small question and a link to the website, under the button of a step.
    private func websiteLink(_ question: String, _ label: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(question).foregroundStyle(.secondary)
            Button(label, action: action)
                .buttonStyle(.plain)
                .foregroundStyle(Ink.accent)
        }
        .font(.system(size: 10.5))
    }

    /// Who reads the pages. A dot for each: the accent while it keeps up, grey when pages changed
    /// more than two hours ago and it has not looked since.
    private var agents: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Agents")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 9)
                .padding(.bottom, 2)
            ForEach(model.agents) { agent in
                AgentRowView(agent: agent) { model.open(agent) }
            }
        }
    }

    /// The person said no when macOS asked for Bluetooth, or a rule on this Mac forbids it. A pen
    /// can then never connect, and nothing else in the panel would say why: the pen is on, the
    /// radio is on, and still nothing happens. One sentence and the one place to change it.
    /// Not a filled button while nothing is written yet: the photo and the agent need no Bluetooth.
    private var bluetoothRefused: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Bluetooth is not allowed")
                .font(.system(size: 11.5, weight: .medium))
            Text("A pen cannot connect until Open Smart Pen may use Bluetooth. Allow it in System Settings. If the pen still does not connect, quit Open Smart Pen and open it again.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Bluetooth Settings", action: model.openBluetoothSettings)
                .buttonStyle(InkButtonStyle(filled: !startsWithoutAPen))
        }
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
        VStack(alignment: .leading, spacing: 0) {
            hairline
            VStack(spacing: 1) {
                // Nothing here for opening a notebook: clicking one in the list above already
                // does that, and "Reveal notes" is a folder you rarely want and can reach from
                // Settings. What is left is what a menubar app's menu is actually for.
                // No shortcuts printed beside them. A non-activating panel does not reliably
                // become key, so the keystrokes it advertised often did nothing — and a
                // shortcut that fails half the time is worse than no shortcut at all. The
                // handler stays; only the promise is gone.
                MenuItem(title: "Add Photo…", symbol: "camera", action: model.addPhoto)
                MenuItem(title: "Ideas…", symbol: "lightbulb", action: model.showIdeas)
                if model.pens.isEmpty, !steps.contains(.pen) {
                    MenuItem(title: "Add Pen…", symbol: "pencil.tip", action: model.addPen)
                }
                MenuItem(title: "Settings…", action: model.openConfig)
                MenuItem(title: "Quit") { NSApp.terminate(nil) }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 5)
            // Nothing about the last sync. It is a timestamp for something that already worked,
            // which is the definition of a line nobody reads — and when it has not worked, the
            // failure block says so in words, above, where it cannot be missed.
        }
    }

    /// Every section is a hairline plus the same padding, so the layout does not repeat either.
    /// `inset` is the block's own left margin. A list of rows takes the smaller one and makes it
    /// up inside each row, so that a row's hover highlight reaches past the text on both sides
    /// while the text itself still lines up with everything above it.
    private func section<Content: View>(inset: CGFloat = 14,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            hairline
            content()
                .padding(.horizontal, inset)
                .padding(.vertical, inset == 14 ? 11 : 6)
        }
    }

    /// Inset to the same margin as everything else, so it reads as a rule between two blocks of
    /// one column rather than as the edge of a box.
    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.11))
            .frame(height: 1)
            .padding(.horizontal, 14)
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
            HStack(spacing: 9) {
                // On the notebook itself, not in a column of its own. The mark belongs to the
                // book, the way an owed badge belongs to an app icon — put it at the start of
                // the line instead and it reads as a bullet, and the title it sits beside is not
                // the thing it is about.
                PaperMark(binding: book.binding, photo: book.page.folder.surface == PhotoPages.surface)
                    .frame(width: 15, height: 15)
                    .overlay(alignment: .topTrailing) {
                        // top:-1, right:-3 against the 15-point mark, as in the design.
                        Circle()
                            .fill(book.latest ? Ink.accent : Color.clear)
                            .frame(width: 5, height: 5)
                            .offset(x: 3, y: -1)
                    }
                Text(book.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
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
struct InkDot: View {
    let colour: Color
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            // Every ink the same size — a row of dots that changed size as you clicked along it
            // would jitter, and the swatch is also how you tell the colours apart, which a
            // smaller one does worse. The unchosen ones step back by weight alone: enough colour
            // to know which is which, not enough to compete with the ink that is loaded.
            //
            // 16 and 6 rather than 14 and 5: an odd difference leaves the punch half a point off
            // the grid on each side, and half a point is exactly the amount that reads as
            // crooked. As an overlay rather than a second stack child, so the punch is centred
            // on the swatch itself and cannot drift from it.
            Circle()
                .fill(colour)
                .opacity(selected ? 1 : hovering ? 0.6 : 0.3)
                .frame(width: 16, height: 16)
                .overlay(Circle()
                    .fill(punch)
                    .frame(width: 6, height: 6)
                    .opacity(selected ? 1 : 0))
                // 2 each side plus the row's 4 makes 8 between swatches. The click target is
                // still bigger than the swatch, which is the only reason the padding is here.
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// What shows through the middle. Yellow needs a dark mark; everything else takes a light one.
    private var punch: Color {
        let srgb = NSColor(colour).usingColorSpace(.sRGB)
        let luminance = srgb.map { 0.299 * $0.redComponent + 0.587 * $0.greenComponent
                                   + 0.114 * $0.blueComponent } ?? 0
        return luminance > 0.6 ? .black : .white
    }
}

/// One line weight, drawn as the line it makes. The chosen one sits on a faint chip — the same
/// grey the panel uses everywhere else, so the selection is legible without being coloured.
struct WidthMark: View {
    let weight: LineWidth
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false

    private var thickness: CGFloat {
        switch weight {
        case .thin: return 1.5
        case .medium: return 3
        case .thick: return 5.5
        default: return 3
        }
    }

    var body: some View {
        Button(action: choose) {
            RoundedRectangle(cornerRadius: thickness / 2, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.9 : hovering ? 0.65 : 0.4))
                .frame(width: 15, height: thickness)
                .frame(width: 26, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.09)
                          : hovering ? Color.primary.opacity(0.05) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(weight.rawValue.capitalized)
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
                Capsule().fill((onInk ?? Color.primary).opacity(0.2))
                // Grey. The violet is how the panel says "this one is live" — on the notebook
                // being written in, and nowhere else — and a charge of 82% is not that. Red
                // only when flat, which is the one thing about a battery worth a colour.
                //
                // Held back on a filled tile, where the usual greys disappear into the ink.
                Capsule().fill(low ? Ink.critical : (onInk ?? Color.secondary))
                    .opacity(onInk == nil ? 0.75 : 0.65)
                    .frame(width: max(4, geo.size.width * CGFloat(percent) / 100))
            }
        }
        .frame(height: 5)
    }
}

/// One pen. Open, the tile fills with that pen's own ink — which is both the selection and the
/// answer to "what does this pen write in". Closed, it shows its battery instead, because a tile
/// you are not using has nothing else worth saying.
///
/// Which pen is in your hand is reported, not asked for: picking one up opens it. A click is
/// only for looking at a pen you are not holding, or for putting the controls away.
/// One agent in the panel. It lights up under the pointer like a notebook does, when there is
/// somewhere to go: an agent that gave no address is a line of text, not a button.
private struct AgentRowView: View {
    let agent: PanelModel.AgentRow
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                Circle()
                    .fill(agent.behind ? Color.primary.opacity(0.25) : Ink.accent)
                    .frame(width: 7, height: 7)
                    .frame(width: 15)
                Text(agent.name)
                    .font(.system(size: 13))
                    .foregroundStyle(agent.behind ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(agent.alive)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                // An agent that gave an address can be opened from here, and says so.
                if agent.url != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(hovering && agent.url != nil ? Color.primary.opacity(0.07) : Color.clear))
        .onHover { hovering = $0 }
        .disabled(agent.url == nil)
        .help(agent.url.map { "Open \(agent.name): \($0.absoluteString)" } ?? "\(agent.name) gave no address to open")
    }
}

private struct PenTile: View {
    let pen: PanelModel.PenRow
    let open: Bool
    let tap: () -> Void

    /// Inked only when the tile is open and the pen is connected. Both halves matter: the fill is
    /// the selection, so a closed tile carries none of it; and the colour is what you are writing
    /// with right now, so a pen that went to sleep twenty minutes ago does not get it either.
    private var filled: Bool { open && pen.awake }
    /// Open, but the pen is off. A plain chip, the same grey the rest of the panel selects with,
    /// so it reads as "this is the one showing" rather than "this is the one writing".
    private var chipped: Bool { open && !pen.awake }

    /// The ink itself, for the fill. A tile filled with true black on a dark panel still reads,
    /// because a filled tile always carries a hairline — it is the 1.4pt glyph that does not.
    private var inkColour: Color {
        Color(inkHex: Palette.hexForPreview(pen.ink)) ?? .primary
    }

    /// The ink as a stroke can carry it, which for black in the dark appearance is not black.
    private var glyphColour: Color { Ink.legible(inkColour) }

    /// What reads on top of the ink when the tile is filled.
    private var onInk: Color {
        pen.ink == .yellow || pen.ink == .white ? .black : .white
    }

    var body: some View {
        Button(action: tap) {
            // Spaced by hand rather than by one stack gap: the bar belongs to the name above it,
            // so it sits nearly against it, while the glyph keeps its own air.
            VStack(spacing: 0) {
                Pencil(colour: filled ? onInk : glyphColour, size: 17)
                // No dot on a filled tile: the fill is already the statement that this is the pen
                // you are using, and "• Pen" reads as a bullet point rather than as a status.
                Text(pen.name)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(filled ? onInk : Color.primary)
                    .lineLimit(1)
                    .padding(.top, 4)
                // Only on the pens you are not using. The open pen states its charge as a
                // number under its name, and a bar saying the same thing directly above it is
                // the panel repeating itself.
                Group {
                    if let percent = pen.percent, !filled {
                        BatteryBar(percent: percent, low: pen.low, onInk: nil)
                    } else {
                        Color.clear.frame(height: 5)
                    }
                }
                .padding(.top, 4)
            }
            // A pen that is not connected drops back, so the one that is stands out without a
            // badge on either. The glyph, the name and the bar fade together; the chip under an
            // open tile does not, because that says which pen is showing, not which is here.
            .opacity(pen.awake ? 1 : 0.55)
            .padding(.horizontal, 4)
            .padding(.top, 7)
            .padding(.bottom, 6)
            .frame(width: 64)
            // No hover chip. The chip is what "open" looks like, so drawing the same shape in
            // the same grey under the pointer says a pen is open when none is — and a row of
            // tiles that lights up as the pointer crosses it is the panel fidgeting.
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(filled ? inkColour
                      : chipped ? Color.primary.opacity(0.09) : Color.clear))
            // A black pen filled with black ink would vanish into a dark panel, so a filled tile
            // always carries a hairline.
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(filled ? 0.16 : 0), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pen.percent.map { "\(pen.name) · \($0)%" } ?? pen.name)
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
/// The two notebook marks, traced from the panel design rather than approximated: every number
/// below is that drawing's own number, on its 16-unit grid, rendered into 15 points exactly as it
/// renders there. Keeping the grid means the two can be compared by reading them side by side.
///
/// A pad is not a plain rectangle. Its glued head — heavier than the outline, a third of the way
/// down — is the entire difference between "a pad" and "a box", and drawing the box alone was the
/// bug this replaces. The bound book's elastic sits *inside* its covers rather than running past
/// them, which is the other thing the approximation got wrong.
private struct PaperMark: View {
    let binding: KnownBooks.Binding
    /// The notebook of pages that arrived as pictures. It is not paper, so it is not drawn as paper.
    var photo = false

    var body: some View {
        Canvas { context, canvas in
            let k = canvas.width / 16          // the design's viewBox, scaled to the frame
            let ink = Color.secondary

            if photo {
                // A picture in a frame: a sun and a hill, in the same line as the paper marks.
                let frame = CGRect(x: 1.8 * k, y: 3 * k, width: 12.4 * k, height: 10 * k)
                context.stroke(Path(roundedRect: frame, cornerRadius: 1.6 * k),
                               with: .color(ink), lineWidth: 1.1 * k)
                context.fill(Path(ellipseIn: CGRect(x: 4.1 * k, y: 5.2 * k, width: 2.3 * k, height: 2.3 * k)),
                             with: .color(ink))
                var hill = Path()
                hill.move(to: CGPoint(x: 2.6 * k, y: 12 * k))
                hill.addLine(to: CGPoint(x: 6.4 * k, y: 9 * k))
                hill.addLine(to: CGPoint(x: 8.4 * k, y: 10.6 * k))
                hill.addLine(to: CGPoint(x: 11 * k, y: 7.6 * k))
                hill.addLine(to: CGPoint(x: 13.6 * k, y: 10.4 * k))
                context.stroke(hill, with: .color(ink),
                               style: StrokeStyle(lineWidth: 1.1 * k, lineCap: .round, lineJoin: .round))
                return
            }

            switch binding {
            case .bound:
                let body = CGRect(x: 2.5 * k, y: 2 * k, width: 10 * k, height: 12 * k)
                context.stroke(Path(roundedRect: body, cornerRadius: 1.6 * k),
                               with: .color(ink), lineWidth: 1.1 * k)
                var elastic = Path()
                elastic.move(to: CGPoint(x: 10.6 * k, y: 2 * k))
                elastic.addLine(to: CGPoint(x: 10.6 * k, y: 14 * k))
                context.stroke(elastic, with: .color(ink), lineWidth: 1.1 * k)
            case .pad:
                let body = CGRect(x: 3 * k, y: 2.5 * k, width: 10 * k, height: 11 * k)
                context.stroke(Path(roundedRect: body, cornerRadius: 1.2 * k),
                               with: .color(ink), lineWidth: 1.1 * k)
                var head = Path()
                head.move(to: CGPoint(x: 3 * k, y: 5.1 * k))
                head.addLine(to: CGPoint(x: 13 * k, y: 5.1 * k))
                context.stroke(head, with: .color(ink), lineWidth: 1.6 * k)
            }
        }
        .frame(width: 15, height: 15)
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
    /// A small picture before the words, for the one entry that is looked for and not read.
    var symbol: String?
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                }
                Text(title).font(.system(size: 13))
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(hovering ? Color.primary.opacity(0.08) : Color.clear))
        .onHover { hovering = $0 }
    }
}
