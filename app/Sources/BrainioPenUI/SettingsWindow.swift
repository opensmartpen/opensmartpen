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

    private let penRegistry: PenRegistry
    private let bookRegistry: BookRegistry
    private let configURL: URL
    /// Told when a setting that the running app cares about has changed.
    public var onConfigChange: ((Config) -> Void)?

    public init(pens: PenRegistry, books: BookRegistry, config: Config, configURL: URL) {
        penRegistry = pens
        bookRegistry = books
        self.config = config
        self.configURL = configURL
        reload()
    }

    func reload() {
        pens = penRegistry.pens
        books = bookRegistry.books.sorted { $0.title < $1.title }
        palette = Palette.load(root: config.dataURL)
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
    /// person a list to pick an agent from instead of an id to copy.
    @MainActor
    func checkDam() async {
        damStatus = "checking…"
        guard let host = config.damHost, !host.isEmpty, !damApiKey.isEmpty else {
            damStatus = "a host and a key are needed"
            return
        }
        do {
            // Any agent id will do for a listing: it is owner-wide and not bound to one.
            let client = try DamClient(account: DamAccount(host: host,
                                                           agentId: config.damAgentId ?? "none",
                                                           apiKey: damApiKey))
            damAgents = try await client.agents()
            damStatus = damAgents.isEmpty ? "the key can see no agents" : "\(damAgents.count) agent(s)"
        } catch {
            damAgents = []
            damStatus = error.localizedDescription
        }
    }

    /// Add an agent to the roster and ask it what it is for, in one go. The question is one turn
    /// against that agent, so it also proves the key reaches it.
    @MainActor
    func addToRoster(_ agent: DamAgent) async {
        if !config.damRoster.contains(where: { $0.id == agent.id }) {
            config.damRoster.append(DamAgentProfile(id: agent.id, name: agent.name))
            saveConfig()
        }
        await ask(agent.id)
    }

    @MainActor
    func removeFromRoster(_ id: String) {
        config.damRoster.removeAll { $0.id == id }
        saveConfig()
    }

    /// Ask one agent, in its own words, what it does and what it can reach.
    @MainActor
    func ask(_ id: String) async {
        guard let host = config.damHost, !host.isEmpty, !damApiKey.isEmpty else {
            damStatus = "a host and a key are needed"
            return
        }
        asking.insert(id)
        defer { asking.remove(id) }
        do {
            let runner = try DamRunner(account: DamAccount(host: host, agentId: id, apiKey: damApiKey))
            let answer = AgentProfileAnswer(try await runner.run(prompt: AgentProfileAnswer.question,
                                                                 timeout: 180).text)
            guard let i = config.damRoster.firstIndex(where: { $0.id == id }) else { return }
            config.damRoster[i].summary = answer.summary
            config.damRoster[i].systems = answer.systems
            config.damRoster[i].askedAt = Date()
            saveConfig()
        } catch {
            damStatus = "\(id): \(error.localizedDescription)"
        }
    }

    /// Agents being asked right now.
    @Published var asking: Set<String> = []

    func saveConfig() {
        do {
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

    public enum Tab: Hashable { case pens, books, general, reading }

    public var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                PensTab(store: store).tabItem { Text("Pens") }.tag(Tab.pens)
                BooksTab(store: store).tabItem { Text("Notebooks") }.tag(Tab.books)
                GeneralTab(store: store).tabItem { Text("General") }.tag(Tab.general)
                ReadingTab(store: store).tabItem { Text("Reading") }.tag(Tab.reading)
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
        .frame(width: 480, height: 430)
    }
}

// MARK: - pens

private struct PensTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.pens.isEmpty {
                    Hint("No pen has connected yet. A pen names itself the first time it does, and "
                         + "you can change that name here.")
                }
                ForEach(store.pens, id: \.slug) { pen in
                    PenCard(pen: pen, palette: store.palette) { store.save($0) }
                }
            }
            .padding(.top, 4)
        }
    }
}

private struct PenCard: View {
    let pen: PenRecord
    let palette: Palette
    let save: (PenRecord) -> Void
    @State private var name: String = ""

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
                Spacer()
                Text("fixed").font(.system(size: 10)).foregroundStyle(.quaternary)
            }
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

// MARK: - reading

/// Where a page goes to be read, and how long it must have been still first.
///
/// Off until a host, a key and an agent are all filled in. The key goes to its own file; the host,
/// the agents and which of them reads pages go to the config.
private struct ReadingTab: View {
    @ObservedObject var store: SettingsStore
    @State private var checking = false

    private var roster: [DamAgentProfile] { store.config.damRoster }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Row("DAM") {
                TextField("https://dam.example.com", text: Binding(
                    get: { store.config.damHost ?? "" },
                    set: { store.config.damHost = $0.isEmpty ? nil : $0; store.saveSoon() }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            }
            Row("Key") {
                SecureField("pk_…", text: $store.damApiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
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

            // The agents, and which of them reads. A list rather than a picker: choosing the
            // reader is choosing which agent sees the paper, and that is a decision to be made
            // looking at what all of them can reach.
            HStack(spacing: 6) {
                Text("Agents").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text("· the marked one reads your pages")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                let spare = store.damAgents.filter { known in !roster.contains { $0.id == known.id } }
                if !spare.isEmpty {
                    Menu("Add") {
                        ForEach(spare) { agent in
                            Button(agent.name) { Task { await store.addToRoster(agent) } }
                        }
                    }
                    .frame(width: 70)
                }
            }

            // Scrolls, and keeps everything under it on screen. Eight agents used to push the host
            // and the key off both ends of the window.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(roster) { agent in
                        AgentRow(store: store, agent: agent,
                                 reads: store.config.damAgentId == agent.id)
                        if agent.id != roster.last?.id { Divider().opacity(0.4) }
                    }
                    if roster.isEmpty {
                        Text(store.damApiKey.isEmpty
                             ? "Put a host and a key in, then press Check."
                             : "Press Check to see what the key can reach.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(10)
                    }
                }
            }
            .frame(maxHeight: 176)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))

            if let status = store.damStatus {
                Hint(status)
            }
            Row("Wait") {
                Stepper(value: $store.config.damQuietMinutes, in: 1...60, step: 1) {
                    Text("\(Int(store.config.damQuietMinutes)) min").font(.system(size: 11)).monospacedDigit()
                }
                .onChange(of: store.config.damQuietMinutes) { _ in store.saveConfig() }
            }
            Spacer(minLength: 0)
            // Short, because the long version was five lines and the biggest thing on the tab.
            // What a person has to know here is why the mark matters.
            Hint("The marked agent sees whatever is written on your paper, so mark one with "
                 + "nothing confidential behind it. It also proposes which agent carries out each "
                 + "line a page asks for, choosing from what the others say they do.")
        }
        .padding(.top, 4)
    }
}

/// One agent on the roster: what it says it does, what it can reach, and whether it is the one
/// that reads pages.
private struct AgentRow: View {
    @ObservedObject var store: SettingsStore
    let agent: DamAgentProfile
    let reads: Bool
    @State private var hovering = false

    private var asking: Bool { store.asking.contains(agent.id) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // One reader at a time. A radio rather than a menu, because the point of the choice is
            // that everything else on this list is not it.
            Button {
                store.config.damAgentId = agent.id
                store.saveConfig()
            } label: {
                Image(systemName: reads ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(reads ? Ink.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Read pages with this agent")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(agent.name).font(.system(size: 11.5, weight: .medium))
                    if reads {
                        Text("reads pages").font(.system(size: 9.5)).foregroundStyle(Ink.accent)
                    }
                }
                Text(asking ? "asking what it does…" : (agent.summary ?? "never asked"))
                    .font(.system(size: 10))
                    .foregroundStyle(agent.summary == nil && !asking ? .tertiary : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !agent.systems.isEmpty {
                    Text(agent.systems.joined(separator: " · "))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            // Quiet until wanted. Eight rows each shouting a button is a wall of buttons.
            Button(agent.summary == nil ? "Ask" : "Again") { Task { await store.ask(agent.id) } }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(asking ? Color.secondary : Ink.accent)
                .disabled(asking)
                .opacity(agent.summary == nil || hovering ? 1 : 0.35)
            Button { store.removeFromRoster(agent.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.25)
            .help("Take it off the list")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 430),
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
