import AppKit
import BrainioPenCore
import SwiftUI

/// The list down the right-hand edge: one line per thing a page asks for, and the conversation
/// with the agent underneath whichever one is open.
public struct ActionsView: View {
    @ObservedObject var store: ActionsStore
    /// The window has no title bar, so the one button it needs lives in the header.
    var close: () -> Void = {}
    @State private var hoveringHeader = false

    public init(store: ActionsStore, close: @escaping () -> Void = {}) {
        self.store = store
        self.close = close
    }

    /// The three piles, in the order a person wants them: what is still to do, what is finished,
    /// and — only when asked for — what was called off. Newest page first inside each: the sheet
    /// you wrote on this morning is the one you mean.
    ///
    /// Each pile is one tile. The tile does what a heading and a row of dividers used to do
    /// between them, and does it more quietly: a group of lines on a shared ground reads as a
    /// group without anything drawn between the lines.
    private struct Pile: Identifiable {
        let id: ActionsStore.Status
        /// Nothing above the first pile: what is owed needs no announcing, because it is the list.
        let title: String?
        let rows: [ActionsStore.Item]
    }

    private var piles: [Pile] {
        let newest: (ActionsStore.Item, ActionsStore.Item) -> Bool = { $0.written > $1.written }
        let rows = { (keep: (ActionsStore.Status) -> Bool) -> [ActionsStore.Item] in
            // A stable sort, so two lines off the same page stay in the order they were written.
            store.items.enumerated()
                .filter { keep($0.element.status) }
                .sorted { a, b in
                    a.element.written == b.element.written ? a.offset < b.offset : newest(a.element, b.element)
                }
                .map(\.element)
        }
        var piles = [
            Pile(id: .new, title: nil, rows: rows { $0 == .new || $0 == .wip }),
            Pile(id: .done, title: "Done", rows: rows { $0 == .done }),
        ]
        if store.showDeleted {
            piles.append(Pile(id: .dismissed, title: "Deleted", rows: rows { $0 == .dismissed }))
        }
        return piles.filter { !$0.rows.isEmpty }
    }

    private var outstanding: Int {
        store.items.filter { $0.status == .new || $0.status == .wip }.count
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if store.items.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(piles) { pile in
                            VStack(alignment: .leading, spacing: 5) {
                                if let title = pile.title {
                                    Text(title)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .textCase(.uppercase)
                                        .kerning(0.5)
                                        .padding(.horizontal, 12)
                                }
                                VStack(spacing: 0) {
                                    ForEach(pile.rows) { item in
                                        ActionCard(store: store, item: item,
                                                   open: store.expanded == item.id)
                                    }
                                }
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
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
            // Deleted lines are out of the way, not gone. One switch brings them back into view,
            // and it only appears once there is something to see. A pill with the word on it,
            // because that is what a filter looks like; a trash can in the title bar looks like a
            // way to throw the list out.
            if store.items.contains(where: { $0.status == .dismissed }) {
                Toggle(isOn: $store.showDeleted) { Text("Deleted") }
                    .toggleStyle(PillToggle())
                    .help(store.showDeleted ? "Hide deleted" : "Show deleted")
            }
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

    private var busy: Bool { store.isBusy(item) || store.isRewording(item) }
    private var faded: Bool { item.status == .done || item.status == .dismissed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                // The mark is the button, as it is on any checklist: the agent says what it did,
                // and this is where you say whether that finished it. It outranks the agent both
                // ways — you can tick what it left open and re-open what it ticked.
                Button { store.setDone(item, item.status != .done) } label: { Mark(status: item.status) }
                    .buttonStyle(.plain)
                    .help(item.status == .done ? "Reopen" : "Mark as done")

                VStack(alignment: .leading, spacing: 3) {
                    // A finished line goes grey and keeps its words. Crossing it out says it was
                    // wrong, and it was not wrong, it was done; the tick already says which.
                    Text(item.text)
                        .font(.system(size: 12.5, weight: .medium))
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
                        // Who it goes to. The transcriber proposed it from the page; a page is not
                        // something to take instructions from, so the answer is always changeable
                        // and always in sight before anything is sent.
                        // Always, not only when a roster exists. Where a line is going is part
                        // of what the line is, and with no agents set up the menu is how you find
                        // out that is what is missing.
                        if item.status == .new || item.status == .wip {
                            Text("·").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                            AgentChip(store: store, item: item)
                        }
                    }
                    // Only while it is still somebody's problem. A finished line does not need its
                    // last sentence repeated under it — that is what opening it is for.
                    if !open, item.status == .new || item.status == .wip,
                       let note = item.action.note, !note.isEmpty {
                        // A question left for you gets its label on a line of its own, above the
                        // question, the way the permission card labels its own. On the caption
                        // line it pushed the notebook's name off the end of the row.
                        if item.action.needsYou {
                            Text("Waiting on you")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Ink.accent)
                                .textCase(.uppercase)
                                .kerning(0.4)
                                .padding(.top, 5)
                        }
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.top, item.action.needsYou ? 1 : 2)
                    } else if !open, item.action.needsYou {
                        Text("Waiting on you")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Ink.accent)
                            .textCase(.uppercase)
                            .kerning(0.4)
                            .padding(.top, 3)
                    }
                }
                if busy {
                    ProgressView().controlSize(.small).scaleEffect(0.65)
                } else {
                    Menu {
                        if store.canRun, item.status == .new || item.status == .wip {
                            // The two say what they keep. "Continue" carries the conversation on
                            // with the same agent and everything it has decided; "Retry from
                            // scratch" throws that away and puts the original line in front of a
                            // fresh agent — for when the first attempt went down the wrong road
                            // and no amount of saying more will bring it back.
                            Button(item.action.thread.isEmpty ? "Ask the agent" : "Continue with the agent") {
                                store.expanded = item.id
                                store.run(item)
                            }
                            .help(item.action.thread.isEmpty
                                  ? "Hand this line to the agent"
                                  : "Send it back to the same agent, which keeps what it has already decided")
                        }
                        // Only once there is something to forget.
                        if store.canRun, !item.action.thread.isEmpty || item.action.session != nil {
                            Button("Retry from scratch") {
                                store.expanded = item.id
                                store.startOver(item)
                            }
                            .help("Forget the conversation and give the line to a fresh agent")
                        }
                        if item.status == .done {
                            Button("Reopen") { store.setDone(item, false) }
                        } else if item.status != .dismissed {
                            Button("Mark as done") { store.setDone(item, true) }
                        }
                        if item.status == .dismissed {
                            Button("Put it back") { store.setDismissed(item, false) }
                        } else {
                            Button("Delete") { store.setDismissed(item, true) }
                        }
                        Divider()
                        // The page's text, not the action: the transcriber gets the whole page, because
                        // "make them lowercase" is about the page and "the name is Ondřej Široký"
                        // fixes the line wherever it appears.
                        if store.canRun {
                            Button("Fix the transcript…") {
                                store.expanded = item.id
                                store.rewordingFrom = item.id
                            }
                            .help("Tell the transcriber what it misread on this page")
                        }
                        Button("Reveal in notebook") { store.onOpenPage?(item.page) }
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { toggle() }

            // Above the conversation and never folded away: the agent is stopped until this is
            // answered, and a question hidden behind a disclosure triangle is a job that quietly
            // fails half an hour later.
            ForEach(store.waiting(item)) { ask in
                Permission(store: store, item: item, ask: ask)
            }

            if store.rewordingFrom == item.id {
                RewordBox(store: store, item: item)
            }

            if open { conversation }
        }
        // The open row sits a shade deeper in the tile. That is all it takes to keep the
        // conversation from running into the rows below now that the tile holds the lines
        // together; a rail down the edge on top of it was two things saying one thing.
        .background(open ? Color.primary.opacity(0.05) : (hovering ? Color.primary.opacity(0.025) : Color.clear))
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
        .padding(.horizontal, 12)
        .padding(.leading, 26)
        .padding(.bottom, 12)
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

/// The agent has been stopped by DAM and wants to be let through.
///
/// Two things arrive here and they are not the same. A **tool call** is the agent asking before it
/// does something inside its own session. An **egress hold** is the platform's own gate: the agent
/// tried to reach a host it has no standing rule for, and the request is held — for half an hour,
/// and then refused — until somebody says yes. Both are shown the same way, because the question a
/// person is answering is the same question: is this line allowed to do that?
///
/// It is drawn on the row rather than in a dialog. A dialog would arrive over whatever you were
/// doing, in an app that is usually not the front one, for a job you started ten minutes ago; the
/// row already says what the job was.
private struct Permission: View {
    @ObservedObject var store: ActionsStore
    let item: ActionsStore.Item
    let ask: ApprovalAsk

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Ink.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ask.isEgress ? "Wants to reach" : "Wants to run")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                        .textCase(.uppercase)
                        .kerning(0.4)
                    Text(ask.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if !ask.detail.isEmpty {
                        Text(ask.detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
            if store.isDeciding(ask) {
                ProgressView().controlSize(.small).scaleEffect(0.65)
            } else {
                HStack(spacing: 6) {
                    Choice(title: "Allow once", strong: true) { store.decide(item, ask, .allowOnce) }
                    // "Always" writes a standing rule in DAM for this agent. Said plainly in the
                    // tooltip, because it is the one answer here that outlives the line.
                    Choice(title: "Always") { store.decide(item, ask, .allowAlways) }
                        .help(ask.isEgress
                              ? "Let this agent reach \(ask.title) from now on, without asking"
                              : "Let this agent do this from now on, without asking")
                    Choice(title: "No") { store.decide(item, ask, .deny) }
                        .help("Just this once. Nothing is written down.")
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Ink.accent.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Ink.accent.opacity(0.3)))
        )
        .padding(.horizontal, 12)
        .padding(.leading, 26)
        .padding(.bottom, 10)
    }
}

/// Where you tell the transcriber what to change about the page's wording.
///
/// On the row rather than in a sheet, like the permission card, and for the same reason: the row
/// says which page, and a sentence like "the name is Ondřej Široký" is written while looking at
/// the line that got it wrong.
private struct RewordBox: View {
    @ObservedObject var store: ActionsStore
    let item: ActionsStore.Item

    @State private var instruction = ""
    @FocusState private var typing: Bool

    private var canSend: Bool {
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Fix the transcript of page \(item.pageNumber)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                    .textCase(.uppercase)
                    .kerning(0.4)
                Spacer(minLength: 0)
                Button { store.rewordingFrom = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Never mind")
            }
            HStack(spacing: 7) {
                TextField("Lowercase, or: the name is Ondřej Široký…", text: $instruction, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .lineLimit(1...4)
                    .focused($typing)
                    .onSubmit(send)
                    .onExitCommand { store.rewordingFrom = nil }
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
                .help("Send to the transcriber")
            }
            // Every line on the page changes, not only this one: said here, once, rather than
            // discovered.
            Text("The transcriber gets the page and every line on it. Nothing is carried out.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Ink.accent.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Ink.accent.opacity(0.3)))
        )
        .padding(.horizontal, 12)
        .padding(.leading, 26)
        .padding(.bottom, 10)
        .onAppear { typing = true }
    }

    private func send() {
        guard canSend else { return }
        store.reword(item, instruction)
        instruction = ""
    }
}

/// One of the three answers. Small, because three of them sit on a 380pt column.
private struct Choice: View {
    let title: String
    var strong = false
    let act: () -> Void

    var body: some View {
        Button(action: act) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(strong ? Ink.accent : Color.primary.opacity(0.07))
                )
                .foregroundStyle(strong ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// Which agent carries this line out, and a menu to change it.
///
/// It reads as a suggestion, not a setting, because that is what it is: the agent that transcribed the
/// page guessed from what each of the others says it can reach. The guess is worth showing before
/// the work is sent, and worth one click to correct.
private struct AgentChip: View {
    @ObservedObject var store: ActionsStore
    let item: ActionsStore.Item

    var body: some View {
        Menu {
            if store.roster.isEmpty {
                Button("Set up agents…") { store.onOpenSettings?() }
            }
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

/// A filter, drawn as one: a small capsule with the word on it, tinted while it is in force.
private struct PillToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(configuration.isOn ? Ink.accent : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(configuration.isOn ? Ink.accent.opacity(0.14) : Color.primary.opacity(0.06))
                )
                .overlay(
                    Capsule().strokeBorder(configuration.isOn ? Ink.accent.opacity(0.45) : Color.clear, lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
