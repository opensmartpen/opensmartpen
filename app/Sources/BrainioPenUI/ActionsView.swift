import AppKit
import BrainioPenCore
import SwiftUI

/// The list down the right-hand edge: one line per thing a page asks for, and the conversation
/// with the agent underneath whichever one is open.
struct ActionsView: View {
    @ObservedObject var store: ActionsStore
    /// The window has no title bar, so the one button it needs lives in the header.
    var close: () -> Void = {}
    @State private var hoveringHeader = false

    /// Everything still to do first, then what has been finished, then what was called off.
    /// Newest page first inside each — the sheet you wrote on this morning is the one you mean.
    private var sorted: [ActionsStore.Item] {
        store.items.enumerated().sorted { a, b in
            let rank = { (item: ActionsStore.Item) -> Int in
                switch item.status {
                case .new, .wip: return 0
                case .done: return 1
                case .dismissed: return 2
                }
            }
            if rank(a.element) != rank(b.element) { return rank(a.element) < rank(b.element) }
            if a.element.written != b.element.written { return a.element.written > b.element.written }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The word that starts a new pile, or nothing when this row is in the same pile as the one
    /// above it.
    private func heading(before item: ActionsStore.Item) -> String? {
        let rows = sorted
        guard let i = rows.firstIndex(where: { $0.id == item.id }) else { return nil }
        let previous = i == 0 ? nil : rows[i - 1].status
        switch item.status {
        case .done where previous != .done: return "Done"
        case .dismissed where previous != .dismissed: return "Not going to happen"
        default: return nil
        }
    }

    private var outstanding: Int {
        store.items.filter { $0.status == .new || $0.status == .wip }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if store.items.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sorted) { item in
                            // A heading where the pile changes character, and none above the
                            // first: what is owed needs no announcing, because it is the list.
                            if let heading = heading(before: item) {
                                Text(heading)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .textCase(.uppercase)
                                    .kerning(0.5)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 16)
                                    .padding(.bottom, 6)
                            }
                            ActionCard(store: store, item: item,
                                       open: store.expanded == item.id)
                            Divider().opacity(0.35).padding(.leading, 38)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .background(VisualEffect(material: .sidebar))
        // Rounded down the side that faces the work, square against the screen edge it is docked
        // to — the shape of a drawer rather than of a floating box.
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10))
        .frame(minWidth: 320)
    }

    /// Sits in the title bar, beside the close button, rather than under it. The window is a
    /// column down the edge of a screen; a strip of empty chrome above a heading that repeats the
    /// window's own name is two things saying nothing.
    /// The whole of the window's chrome: what it is, how much is owed, and the way out.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Actions")
                .font(.system(size: 13, weight: .semibold))
            if outstanding > 0 {
                Text("\(outstanding) to do")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hoveringHeader ? Color.secondary : Color.secondary.opacity(0.45))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 11)
        .onHover { hoveringHeader = $0 }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("Nothing asked for yet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("A line that starts with ≫ on paper turns up here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

/// One line, shut or open.
///
/// Shut it is a mark, the words, and where they were written. Open it is the whole exchange with
/// the agent and a box to say the next thing — which is the only place in the app where you talk
/// to it, so it is given the room.
private struct ActionCard: View {
    @ObservedObject var store: ActionsStore
    let item: ActionsStore.Item
    let open: Bool

    @State private var reply = ""
    @State private var hovering = false
    @FocusState private var typing: Bool

    private var busy: Bool { store.isBusy(item) }
    private var faded: Bool { item.status == .done || item.status == .dismissed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                // The mark is the button, as it is on any checklist: the agent says what it did,
                // and this is where you say whether that finished it. It outranks the agent both
                // ways — you can tick what it left open and re-open what it ticked.
                Button { store.setDone(item, item.status != .done) } label: { Mark(status: item.status) }
                    .buttonStyle(.plain)
                    .help(item.status == .done ? "Not done after all" : "Done")

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.text)
                        .font(.system(size: 12.5, weight: .medium))
                        .strikethrough(faded, color: .secondary)
                        .foregroundStyle(faded ? Color.secondary : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Where it was written and who it goes to, on one line. Two lines of grey
                    // under every title turned the list into a wall: the words a person is reading
                    // for are in the title, and everything else is a caption.
                    HStack(spacing: 4) {
                        Text("\(item.book) · page \(item.pageNumber)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        // Who it goes to. The reader proposed it from the page; a page is not
                        // something to take instructions from, so the answer is always changeable
                        // and always in sight before anything is sent.
                        if !store.roster.isEmpty, item.status == .new || item.status == .wip {
                            Text("·").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                            AgentChip(store: store, item: item)
                        }
                        if item.action.needsYou, !open {
                            Text("waiting on you")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Ink.accent)
                        }
                    }
                    // Only while it is still somebody's problem. A finished line does not need its
                    // last sentence repeated under it — that is what opening it is for.
                    if !open, item.status == .new || item.status == .wip,
                       let note = item.action.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }
                if busy {
                    ProgressView().controlSize(.small).scaleEffect(0.65)
                } else {
                    Menu {
                        if store.canRun, item.status == .new || item.status == .wip {
                            Button(item.action.thread.isEmpty ? "Ask the agent" : "Ask it again") {
                                store.expanded = item.id
                                store.run(item)
                            }
                        }
                        if item.status == .done {
                            Button("Not done after all") { store.setDone(item, false) }
                        } else if item.status != .dismissed {
                            Button("Done") { store.setDone(item, true) }
                        }
                        if item.status == .dismissed {
                            Button("Put it back") { store.setDismissed(item, false) }
                        } else {
                            Button("Not going to happen") { store.setDismissed(item, true) }
                        }
                        Divider()
                        Button("Open the page") { store.onOpenPage?(item.page) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 16)
                    // Faint until wanted, rather than hidden until wanted. A control that appears
                    // under the pointer makes a list flicker as you read down it, and a column of
                    // thirteen of them appearing one at a time is worse than a column of quiet
                    // ones.
                    .opacity(hovering || open ? 1 : 0.3)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture { toggle() }

            if open { conversation }
        }
        .background(open ? Color.primary.opacity(0.07) : (hovering ? Color.primary.opacity(0.025) : Color.clear))
        // A rail down the edge of whichever row is open. Without it the conversation runs into the
        // rows below and the list stops looking like a list.
        .overlay(alignment: .leading) {
            if open {
                Rectangle().fill(Ink.accent).frame(width: 2)
            }
        }
        .onHover { hovering = $0 }
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.14)) {
            store.expanded = open ? nil : item.id
        }
    }

    /// What has been said, and the box for saying the next thing.
    private var conversation: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(item.action.thread.enumerated()), id: \.offset) { _, message in
                Bubble(message: message)
            }
            if let failure = store.failure(item) {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.canRun, item.status != .dismissed {
                HStack(spacing: 7) {
                    TextField(prompt, text: $reply, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .lineLimit(1...6)
                        .focused($typing)
                        .onSubmit(send)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color.primary.opacity(0.06))
                                .overlay(RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(typing ? Ink.accent.opacity(0.55) : Color.primary.opacity(0.1)))
                        )
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 17))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? Ink.accent : Color.secondary.opacity(0.4))
                    .disabled(!canSend)
                    .help(item.action.thread.isEmpty ? "Ask the agent" : "Send")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.leading, 24)
        .padding(.bottom, 14)
    }

    /// The box says what saying something would do, which changes with where the line has got to.
    private var prompt: String {
        if item.action.needsYou { return "Answer it…" }
        if item.action.thread.isEmpty { return "Ask the agent to do this…" }
        return "Say more…"
    }

    private var canSend: Bool {
        !busy && !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        store.run(item, say: reply)
        reply = ""
    }
}

/// Which agent carries this line out, and a menu to change it.
///
/// It reads as a suggestion, not a setting, because that is what it is: the agent that read the
/// page guessed from what each of the others says it can reach. The guess is worth showing before
/// the work is sent, and worth one click to correct.
private struct AgentChip: View {
    @ObservedObject var store: ActionsStore
    let item: ActionsStore.Item

    var body: some View {
        Menu {
            ForEach(store.roster) { agent in
                Button {
                    store.setAgent(item, to: agent.id)
                } label: {
                    // A tick beside the one in force, and its own sentence under it, so the choice
                    // is made on what an agent does rather than on what it is called.
                    Text(item.action.agent == agent.id ? "✓ \(agent.name)" : agent.name)
                }
                .help(agent.summary ?? "")
            }
            Divider()
            Button("Nobody in particular") { store.setAgent(item, to: nil) }
        } label: {
            Text(store.agentName(item) ?? "unrouted")
                .font(.system(size: 10.5))
                .lineLimit(1)
                .foregroundStyle(store.agentName(item) == nil ? Color.secondary : Ink.accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// One thing said, by you or by the agent. The agent's words are the deliverable — what you asked
/// it to find out — so they are selectable, never truncated, and rendered rather than left as
/// asterisks.
private struct Bubble: View {
    let message: ActionMessage

    private var mine: Bool { message.from == .you }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(mine ? "You" : "Agent")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(mine ? Color.secondary : Ink.accent)
                .textCase(.uppercase)
                .kerning(0.4)
            // A reply that came back empty. Nothing is written into a thread empty any more, but
            // files written before that was fixed are still on disk, and a grey void reads as a
            // broken app rather than as a quiet agent.
            MarkdownText(message.text.isEmpty ? "*(said nothing)*" : message.text)
                .font(.system(size: 11.5))
                .foregroundStyle(mine ? Color.secondary : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, mine ? 0 : 10)
        .padding(.vertical, mine ? 0 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Only the agent gets a card. Two identical boxes down the column read as a form; what a
        // person is looking for in there is the answer, and the answer is the agent's.
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(mine ? Color.clear : Color.primary.opacity(0.06))
        )
    }
}

/// The mark: a ring for a line nobody has touched, a filled ring for one in hand, a tick for one
/// that is finished, a cross for one called off. Drawn rather than symboled so the three sizes
/// agree and the ring is the same ring in all four.
private struct Mark: View {
    let status: ActionsStore.Status

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(colour, lineWidth: 1.4)
                .frame(width: 14, height: 14)
            switch status {
            case .new: EmptyView()
            case .wip: Circle().fill(colour).frame(width: 6, height: 6)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(colour)
            case .dismissed:
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(colour)
            }
        }
        .frame(width: 16, height: 16)
        .padding(.top, 1)
        .contentShape(Rectangle())
    }

    /// Violet for what is in hand — it is the only thing on the list that is moving. Everything
    /// else is quiet: a finished line should not shout, and a line nobody has started is not news.
    private var colour: Color {
        switch status {
        case .new: return .secondary
        case .wip: return Ink.accent
        case .done: return .secondary
        case .dismissed: return Color.secondary.opacity(0.5)
        }
    }
}

/// Markdown as the agent writes it: bold, italics, links, and lines that begin with a dash.
///
/// `AttributedString` does the inline part and knows nothing about lists, so the lines are taken
/// one at a time and a dash becomes a bullet. That is the whole of it — this is a reply in a
/// side panel, not a document, and the alternative was reading `**Ondřej Široký**` with the stars
/// still on.
struct MarkdownText: View {
    private let lines: [Line]

    private struct Line: Identifiable {
        let id: Int
        let text: AttributedString
        let bullet: Bool
        let blank: Bool
    }

    init(_ raw: String) {
        lines = raw.components(separatedBy: .newlines).enumerated().map { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var body = trimmed
            var bullet = false
            for marker in ["- ", "* ", "• "] where body.hasPrefix(marker) {
                body = String(body.dropFirst(marker.count))
                bullet = true
                break
            }
            // A heading loses its hashes and keeps its weight from being bold in the text itself,
            // which is how these replies are written anyway.
            while body.hasPrefix("#") { body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces) }
            let attributed = (try? AttributedString(
                markdown: body,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(body)
            return Line(id: index, text: attributed, bullet: bullet,
                        blank: trimmed.isEmpty)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines) { line in
                if line.blank {
                    Spacer().frame(height: 4)
                } else if line.bullet {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(line.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 2)
                } else {
                    Text(line.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// The window's own background, so the panel sits on the desktop the way a sidebar does.
private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
