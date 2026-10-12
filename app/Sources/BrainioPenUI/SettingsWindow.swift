import AppKit
import BrainioPenCore
import SwiftUI

/// Everything that has a name or a number you might want to change.
///
/// The panel deliberately carries almost no words, which only works if there is somewhere else to
/// put them. This is that place: the pens and the notebooks, where naming actually happens, plus
/// the handful of settings that were previously only reachable by editing JSON by hand.
public final class SettingsStore: ObservableObject {
    @Published var pens: [PenRecord] = []
    @Published var books: [BookRecord] = []
    @Published var config: Config
    @Published var palette = Palette()

    /// Looking for a new pen, after "Add pen…".
    @Published var adding = false
    /// MACs of the pens connected right now.
    @Published var connected: Set<String> = []

    private let penRegistry: PenRegistry
    private let bookRegistry: BookRegistry
    private let configURL: URL
    /// The running pens, for pairing. Nil in the design window, which has no pens.
    private weak var link: PenLink?
    private var pairedMacs: [String] = []
    /// Told when a setting that the running app cares about has changed.
    public var onConfigChange: ((Config) -> Void)?

    public init(pens: PenRegistry, books: BookRegistry, config: Config, configURL: URL,
                link: PenLink? = nil) {
        penRegistry = pens
        bookRegistry = books
        self.config = config
        self.configURL = configURL
        self.link = link
        readLink()
        reload()
    }

    /// The app calls this on every change from the pens. Cheap unless something moved.
    public func linkChanged() {
        let before = pairedMacs
        readLink()
        if pairedMacs != before { reload() }
    }

    private func readLink() {
        guard let link else { return }
        pairedMacs = link.pairedMacs
        if adding != link.isAdding { adding = link.isAdding }
        let now = Set(link.connections.filter(\.isConnected).map(\.mac))
        if connected != now { connected = now }
    }

    func addPen() { link?.addPen(); readLink() }
    func cancelAdding() { link?.cancelAdding(); readLink() }

    func forget(_ pen: PenRecord) {
        link?.forgetPen(mac: pen.mac)
        linkChanged()
    }

    public func reload() {
        // Only the pens this Mac accepts. A forgotten pen's record stays in the repo for the
        // strokes it already wrote, but there is nothing left to set on it here.
        let paired = Set(pairedMacs)
        pens = link == nil ? penRegistry.pens : penRegistry.pens.filter { paired.contains($0.mac) }
        books = bookRegistry.books.sorted { $0.title < $1.title }
        palette = Palette.load(root: config.dataURL)
        // The agents tab is a list of what the key can see, so the list is fetched when the window
        // opens rather than only when somebody presses Check. Quietly: a failure here is shown
        // where the rows would be, not as an alarm over a tab nobody is looking at.
        if damAgents.isEmpty, let host = config.damHost, !host.isEmpty, !damApiKey.isEmpty {
            Task { @MainActor in await self.fetchAgents(announce: false) }
        }
    }

    func save(_ pen: PenRecord) {
        penRegistry.save(pen)
        reload()
    }

    func save(_ book: BookRecord) {
        bookRegistry.save(book)
        reload()
    }

    /// The API key, held here only while the window is open. It is written to its own file beside
    /// the config, never into the config itself, so the config stays safe to paste.
    @Published var damApiKey = DamKey.read() ?? ""
    /// What the last check said, for the person who has just typed a host in.
    @Published var damStatus: String?
    @Published var damAgents: [DamAgent] = []

    /// The key, a moment after typing stops. Same reason as the rest, and one more: a key is
    /// pasted, and a paste with no Return after it was silently doing nothing.
    func saveKeySoon() {
        keyPause?.invalidate()
        keyPause = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.saveDamKey() }
        }
    }

    private var keyPause: Timer?

    func saveDamKey() {
        do {
            try DamKey.write(damApiKey)
            onConfigChange?(config)
            noteSaved()
        } catch {
            Log.error("writing the DAM key failed: \(error)")
            damStatus = error.localizedDescription
        }
    }

    /// Ask the server who we are talking to. Proves the host and the key in one call, and gives the
    /// person a list to pick from instead of an id to copy.
    @MainActor
    func checkDam() async { await fetchAgents(announce: true) }

    /// The list of agents the key can see. `announce` says whether the outcome goes in the status
    /// line: yes when somebody pressed Check, no when the window merely opened.
    @MainActor
    private func fetchAgents(announce: Bool) async {
        guard let host = config.damHost, !host.isEmpty, !damApiKey.isEmpty else {
            if announce { damStatus = "a host and a key are needed" }
            return
        }
        if announce { damStatus = "checking…" }
        do {
            // Any agent id will do for a listing: it is owner-wide and not bound to one.
            let client = try DamClient(account: DamAccount(host: host,
                                                           agentId: config.damAgentId ?? "none",
                                                           apiKey: damApiKey))
            damAgents = try await client.agents()
            damStatus = damAgents.isEmpty ? "the key can see no agents"
                : (announce ? "\(damAgents.count) agent(s)" : nil)
        } catch {
            damAgents = []
            damStatus = error.localizedDescription
        }
    }

    /// Which agent transcribes pages. Nil switches transcription off.
    ///
    /// The transcriber cannot also be an assistant: it has no connections, so offering it a line
    /// says nothing, and the point of the split is that the agent that sees the paper is not one
    /// of the agents that can act on it.
    @MainActor
    func setTranscriber(_ id: String?) {
        config.damAgentId = id
        if let id { config.damRoster.removeAll { $0.id == id } }
        saveConfig()
    }

    /// Switch an assistant on: put it on the roster and ask it what it does, in one go.
    ///
    /// The question is the setup. Until the agent has answered it is on the list but offered
    /// nowhere, because the transcriber chooses by what each assistant says it can reach. An agent
    /// that cannot be asked cannot be used, so a failed question switches it off again and the
    /// row says why.
    @MainActor
    func switchOn(_ agent: DamAgent) async {
        failures[agent.id] = nil
        if !config.damRoster.contains(where: { $0.id == agent.id }) {
            config.damRoster.append(DamAgentProfile(id: agent.id, name: agent.name))
            saveConfig()
        }
        let answered = await ask(agent.id)
        if !answered, config.damRoster.first(where: { $0.id == agent.id })?.summary == nil {
            config.damRoster.removeAll { $0.id == agent.id }
            saveConfig()
        }
    }

    @MainActor
    func switchOff(_ id: String) {
        failures[id] = nil
        config.damRoster.removeAll { $0.id == id }
        saveConfig()
    }

    /// Ask one agent, in its own words, what it does and what it can reach. True when it answered.
    @MainActor
    @discardableResult
    func ask(_ id: String) async -> Bool {
        guard let host = config.damHost, !host.isEmpty, !damApiKey.isEmpty else {
            failures[id] = "a host and a key are needed"
            return false
        }
        asking.insert(id)
        defer { asking.remove(id) }
        do {
            let runner = try DamRunner(account: DamAccount(host: host, agentId: id, apiKey: damApiKey))
            let answer = AgentProfileAnswer(try await runner.run(prompt: AgentProfileAnswer.question,
                                                                 timeout: 180).text)
            guard let i = config.damRoster.firstIndex(where: { $0.id == id }) else { return false }
            config.damRoster[i].summary = answer.summary
            config.damRoster[i].systems = answer.systems
            config.damRoster[i].askedAt = Date()
            failures[id] = nil
            saveConfig()
            return true
        } catch {
            failures[id] = error.localizedDescription
            return false
        }
    }

    /// Agents being asked right now.
    @Published var asking: Set<String> = []
    /// What went wrong the last time each agent was asked, shown on its row until it answers.
    @Published var failures: [String: String] = [:]

    func saveConfig() {
        do {
            // Which pens are paired is the pen session's to write, and it can change while this
            // window is open. The file's list wins over the copy this window opened with.
            if let onDisk = try? Config.loadOrCreate(at: configURL) {
                config.pairedPens = onDisk.pairedPens
            }
            try config.save(to: configURL)
            onConfigChange?(config)
            noteSaved()
        } catch {
            Log.error("saving config failed: \(error)")
            saved = "could not save: \(error.localizedDescription)"
        }
    }

    /// What the window says about the last save, and when it stops saying it.
    ///
    /// A settings window that changes a file silently leaves everybody pressing Return to find out
    /// whether it took. This is the answer to that question, in the corner, for a few seconds.
    @Published var saved: String?
    private var savedUntil: Timer?

    private func noteSaved() {
        saved = "Saved"
        savedUntil?.invalidate()
        savedUntil = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.saved = nil }
        }
    }

    /// Save a field a moment after typing stops. Nothing here is worth a Save button, and nothing
    /// here should need the Return key — that is a rule somebody has to be told, and nobody is.
    func saveSoon() {
        typingPause?.invalidate()
        typingPause = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.saveConfig() }
        }
    }

    private var typingPause: Timer?
}

public struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    /// Which page it opens on. "Set up agents…" on an action has somewhere to go.
    @State var tab: Tab = .pens

    public enum Tab: Hashable { case pens, books, general, agents }

    public var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                PensTab(store: store).tabItem { Text("Pens") }.tag(Tab.pens)
                BooksTab(store: store).tabItem { Text("Notebooks") }.tag(Tab.books)
                GeneralTab(store: store).tabItem { Text("General") }.tag(Tab.general)
                AgentsTab(store: store).tabItem { Text("Agents") }.tag(Tab.agents)
            }
            // Nothing here has a Save button, so something has to say that a change landed. One
            // line, in the same place whichever tab you are on, gone a few seconds later.
            HStack(spacing: 5) {
                if let saved = store.saved {
                    Image(systemName: saved == "Saved" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(saved == "Saved" ? Ink.accent : Ink.critical)
                    Text(saved).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("Changes are kept as you make them")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(height: 18)
            .padding(.top, 8)
        }
        .padding(16)
        .frame(width: 560, height: 600)
    }
}

// MARK: - pens

private struct PensTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                AddPen(store: store)
                if store.pens.isEmpty {
                    Hint("No pen has connected yet. A pen names itself the first time it does, and "
                         + "you can change that name here.")
                }
                ForEach(store.pens, id: \.slug) { pen in
                    PenCard(pen: pen, palette: store.palette, connected: store.connected.contains(pen.mac),
                            save: { store.save($0) }, forget: { store.forget(pen) })
                }
            }
            .padding(.top, 4)
        }
    }
}

/// Pairing a pen is the one thing here that waits on the hardware, so it says what it is waiting
/// for: a pen that is switched on. Only one new pen is taken, and only while this is looking.
private struct AddPen: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        HStack(spacing: 8) {
            if store.adding {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                Text("Looking for a new pen. Switch it on near this Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.cancelAdding() }
            } else {
                Spacer()
                Button("Add pen…") { store.addPen() }
            }
        }
        .frame(minHeight: 22)
    }
}

private struct PenCard: View {
    let pen: PenRecord
    let palette: Palette
    let connected: Bool
    let save: (PenRecord) -> Void
    let forget: () -> Void
    @State private var name: String = ""
    @State private var confirmingForget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("Name").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                TextField("Pen", text: $name, onCommit: commit)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { name = pen.name }
            }
            Row("Mode") {
                Picker("", selection: binding(\.mode)) {
                    ForEach(PenMode.allCases, id: \.rawValue) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Row("Default ink") {
                InkPicker(selection: binding(\.ink), palette: palette)
            }
            Row("Default width") {
                // Three, because the paper strip has three buttons. `LineWidth.default` is not a
                // fourth width you can pick — it is the state before anything has been tapped, and
                // offering it here would be offering "unset" as a setting.
                WidthChoice(selection: binding(\.width))
            }
            Row("Hardware") {
                Text(pen.mac).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                Text(connected ? "connected" : "not connected").font(.system(size: 10)).foregroundStyle(.quaternary)
                Spacer()
                Button("Forget…") { confirmingForget = true }
                    .controlSize(.small)
            }
        }
        .confirmationDialog("Forget \(pen.name)?", isPresented: $confirmingForget) {
            Button("Forget", role: .destructive, action: forget)
        } message: {
            Text("This Mac stops syncing from it. Notes it already wrote stay. Add it again to use it.")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func commit() {
        var updated = pen
        updated.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? pen.name : name
        save(updated)
    }

    private func binding<V>(_ path: WritableKeyPath<PenRecord, V>) -> Binding<V> {
        Binding(get: { pen[keyPath: path] },
                set: { new in var u = pen; u[keyPath: path] = new; save(u) })
    }
}

/// The three weights the strip offers. A plain row rather than a Picker, because the stored value
/// can be `.default` — a pen that has never been given one — and a segmented Picker with nothing
/// matching draws a selection anyway and lies about it.
private struct WidthChoice: View {
    @Binding var selection: LineWidth
    private let choices: [LineWidth] = [.thin, .medium, .thick]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(choices, id: \.rawValue) { weight in
                Button { selection = weight } label: {
                    Text(weight.rawValue.capitalized)
                        .font(.system(size: 11, weight: selection == weight ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(selection == weight ? Color.accentColor.opacity(0.25)
                                  : Color.primary.opacity(0.06)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct InkPicker: View {
    @Binding var selection: InkColor
    let palette: Palette

    var body: some View {
        HStack(spacing: 5) {
            ForEach(choices, id: \.rawValue) { colour in
                let hex = palette.hex(for: colour)
                Button { selection = colour } label: {
                    Group {
                        if let fill = swatch(hex) {
                            Circle().fill(fill).overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                        } else {
                            Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.5]))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.primary, lineWidth: selection == colour ? 1.5 : 0).padding(-2.5))
                    .padding(2)
                }
                .buttonStyle(.plain)
                .help(hex == nil ? "\(colour.rawValue) — no colour assigned" : colour.rawValue)
            }
        }
    }

    /// A pen may still name an ink the repo has stopped offering. Show it rather than silently
    /// dropping it, so the setting is visible and can be changed.
    private var choices: [InkColor] {
        palette.offered.contains(selection) ? palette.offered : palette.offered + [selection]
    }

    private func swatch(_ hex: String?) -> Color? {
        guard var h = hex else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return Color(.sRGB, red: Double((v >> 16) & 0xff) / 255,
                     green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

// MARK: - notebooks

private struct BooksTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Hint("The title is yours to change at any time, and nothing moves when you do. "
                     + "The folder is named by an id that means nothing, fixed when the notebook "
                     + "was first seen.")
                ForEach(store.books, id: \.folder) { book in
                    BookCard(book: book) { store.save($0) }
                }
            }
            .padding(.top, 4)
        }
    }
}

private struct BookCard: View {
    let book: BookRecord
    let save: (BookRecord) -> Void
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Title").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                TextField("Notebook", text: $title, onCommit: commit)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { title = book.title }
            }
            Row("Folder") {
                Text("books/\(book.folder.name)/").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                Spacer()
                Text("fixed").font(.system(size: 10)).foregroundStyle(.quaternary)
            }
            Row("Paper") {
                Text(paper).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private var paper: String {
        guard let w = book.widthMM, let h = book.heightMM else { return "size not recorded" }
        return String(format: "%.0f × %.0f mm", w, h)
    }

    private func commit() {
        var updated = book
        updated.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? book.title : title
        save(updated)
    }
}

// MARK: - general

private struct GeneralTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Row("Notes") {
                Text(store.config.dataPath).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                Spacer()
                Button("Reveal") { NSWorkspace.shared.open(store.config.dataURL) }
            }
            Row("Wait before syncing") {
                Stepper(value: $store.config.quietMinutes, in: 1...120, step: 1) {
                    Text("\(Int(store.config.quietMinutes)) min").font(.system(size: 11)).monospacedDigit()
                }
                .onChange(of: store.config.quietMinutes) { _ in store.saveConfig() }
            }
            Row("Low battery at") {
                Stepper(value: $store.config.lowBatteryPercent, in: 5...50, step: 5) {
                    Text("\(store.config.lowBatteryPercent)%").font(.system(size: 11)).monospacedDigit()
                }
                .onChange(of: store.config.lowBatteryPercent) { _ in store.saveConfig() }
            }
            Toggle("Push to the remote after every commit", isOn: $store.config.gitPush)
                .onChange(of: store.config.gitPush) { _ in store.saveConfig() }
            Hint("Off, the notes repo stays on this Mac. Turn it on only when the repo has an "
                 + "origin remote you want the notes copied to.")
            Toggle("Clear a notebook from the pen once it is synced",
                   isOn: $store.config.deleteFromPenAfterPublish)
                .onChange(of: store.config.deleteFromPenAfterPublish) { _ in store.saveConfig() }
            Spacer()
            Hint("Colours and line widths live in palette.json in the notes repo, so Brainio Pen and "
                 + "the renderer cannot disagree about what red looks like.")
        }
        .padding(.top, 4)
    }
}

// MARK: - agents

/// Where pages go, who transcribes them, and which assistants a line can be handed to.
///
/// Three parts, in the order they are needed. The connection: a host and a key, proved by Check.
/// The transcriber: one agent, chosen alone, because it is the one that sees the paper. The
/// assistants: every other agent the key can see, each with a switch, because an agent is either
/// something a line can be handed to or it is not.
private struct AgentsTab: View {
    @ObservedObject var store: SettingsStore
    @State private var checking = false

    private var transcriberId: String? { store.config.damAgentId }

    /// What the transcriber picker offers: everything the key can see, plus the one already chosen
    /// when the key can no longer see it — so the choice is shown rather than silently blanked.
    private var transcriberChoices: [DamAgent] {
        var choices = store.damAgents
        if let id = transcriberId, !choices.contains(where: { $0.id == id }) {
            choices.append(DamAgent(id: id, name: store.config.damRoster.first { $0.id == id }?.name ?? id))
        }
        return choices
    }

    /// Every agent that could be an assistant: what the key sees, minus the transcriber, plus any
    /// on the roster the key no longer sees, which are kept so they can be switched off.
    private var candidates: [DamAgent] {
        var list = store.damAgents.filter { $0.id != transcriberId }
        for kept in store.config.damRoster where kept.id != transcriberId
            && !list.contains(where: { $0.id == kept.id }) {
            list.append(DamAgent(id: kept.id, name: kept.name))
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Three cards, like the pens tab: each thing you set up has its own ground, and the
            // one that sees your paper is not on the same list as the ones that act on it.
            Card {
                Row("DAM") {
                    TextField("https://dam.example.com", text: Binding(
                        get: { store.config.damHost ?? "" },
                        set: { store.config.damHost = $0.isEmpty ? nil : $0; store.saveSoon() }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                Row("Key") {
                    SecureField("pk_…", text: $store.damApiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: store.damApiKey) { _ in store.saveKeySoon() }
                    Button(checking ? "Checking…" : "Check") {
                        checking = true
                        Task {
                            store.saveDamKey()
                            await store.checkDam()
                            checking = false
                        }
                    }
                    .disabled(checking)
                }
                // Its own line, under the key. Beside the button it fought the field for width
                // and lost, and a status you have to guess the end of is no status.
                if let status = store.damStatus {
                    Row("") {
                        Text(status).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Card(title: "Transcriber", note: "the one agent that sees everything you write") {
                Row("Agent") {
                    Picker("", selection: Binding(
                        get: { transcriberId },
                        set: { store.setTranscriber($0) }
                    )) {
                        Text("None — pages are kept, not transcribed").tag(String?.none)
                        ForEach(transcriberChoices) { agent in
                            Text(agent.name).tag(Optional(agent.id))
                        }
                    }
                    .labelsHidden()
                    .disabled(transcriberChoices.isEmpty)
                }
                Row("Wait") {
                    Stepper(value: $store.config.damQuietMinutes, in: 1...60, step: 1) {
                        Text("\(Int(store.config.damQuietMinutes)) min after the pen stops")
                            .font(.system(size: 11)).monospacedDigit()
                    }
                    .onChange(of: store.config.damQuietMinutes) { _ in store.saveConfig() }
                }
                Hint("Pick an agent with nothing confidential behind it: a page is an untrusted "
                     + "document. It also proposes which assistant carries out each line a page asks for.")
            }

            Card(title: "Assistants", note: "switch one on to hand it lines", fills: true) {
                // Scrolls, and keeps everything above it on screen. Eight agents used to push the
                // host and the key off both ends of the window.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(candidates) { agent in
                            AssistantRow(store: store, agent: agent,
                                         profile: store.config.damRoster.first { $0.id == agent.id },
                                         seen: store.damAgents.contains { $0.id == agent.id })
                            if agent.id != candidates.last?.id { Divider().opacity(0.4) }
                        }
                        if candidates.isEmpty {
                            Text(emptyNote)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 10)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                Hint("An assistant is asked what it does and what it can reach when it is switched on. "
                     + "Until it has answered, no line is offered to it.")
            }
        }
        .padding(.top, 4)
    }

    private var emptyNote: String {
        if store.damApiKey.isEmpty || (store.config.damHost ?? "").isEmpty {
            return "Put a host and a key in, then press Check."
        }
        if store.damAgents.isEmpty { return "Press Check to see what the key can reach." }
        return "The key sees no agent other than the transcriber."
    }
}

/// One block of the tab on its own ground, the way a pen has its card. An optional title, with a
/// quiet note beside it saying what the block is for; `fills` lets one card take the height left.
private struct Card<Content: View>: View {
    let title: String?
    let note: String?
    let fills: Bool
    @ViewBuilder let content: () -> Content

    init(title: String? = nil, note: String? = nil, fills: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.note = note
        self.fills = fills
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    if let note {
                        Text(note).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

/// One agent that could be an assistant: a switch, what it says it does, and what it can reach.
///
/// The switch is the whole interface. On means the agent was asked and answered, and a line can
/// now be handed to it; off means it is nothing to this app. In between, while the question is
/// out, the row says so — and if the question fails, the switch falls back and the row says why.
private struct AssistantRow: View {
    @ObservedObject var store: SettingsStore
    let agent: DamAgent
    /// On the roster, with whatever it has said. Nil means switched off.
    let profile: DamAgentProfile?
    /// Whether the key can still see it. A row the key cannot see is kept only to be switched off.
    let seen: Bool
    @State private var hovering = false

    private var asking: Bool { store.asking.contains(agent.id) }
    private var isOn: Bool { profile != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { on in
                    if on { Task { await store.switchOn(agent) } } else { store.switchOff(agent.id) }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(asking || (!seen && !isOn))
            .help(isOn ? "Switch it off: no line is handed to it" : "Switch it on and ask what it does")
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.name).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isOn || seen ? .primary : .secondary)
                    if !seen {
                        Text("not seen by this key").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    // Quiet until wanted. Eight rows each shouting a button is a wall of buttons.
                    if isOn, seen {
                        Button(store.failures[agent.id] == nil ? "Ask again" : "Retry") {
                            Task { await store.ask(agent.id) }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(asking ? Color.secondary : Ink.accent)
                        .disabled(asking)
                        .opacity(store.failures[agent.id] != nil || hovering ? 1 : 0)
                        .help("Ask it again what it does and what it can reach")
                    }
                }
                if let failure = store.failures[agent.id] {
                    Text(failure)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Ink.critical)
                        .fixedSize(horizontal: false, vertical: true)
                } else if asking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                        Text("setting up — asking what it does…")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                } else if let profile {
                    Text(profile.summary ?? "did not say what it does")
                        .font(.system(size: 10.5))
                        .foregroundStyle(profile.summary == nil ? .tertiary : .secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if !profile.systems.isEmpty {
                        Text(profile.systems.joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("off — no line is handed to it")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
        }
        // Room on the right for the scroll bar, which otherwise sits on the row's own button.
        .padding(.leading, 2)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - pieces

private struct Row<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            content()
        }
    }
}

private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - window

public final class SettingsWindowController: NSWindowController {
    let store: SettingsStore

    public init(store: SettingsStore, tab: SettingsView.Tab = .pens) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Brainio Pen Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(store: store, tab: tab))
        window.setFrameAutosaveName("brainio-pen-settings")
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public override func showWindow(_ sender: Any?) {
        store.reload()
        super.showWindow(sender)
    }
}
