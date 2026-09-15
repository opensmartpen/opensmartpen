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

    func saveDamKey() {
        do {
            try DamKey.write(damApiKey)
            onConfigChange?(config)
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
        } catch {
            Log.error("saving config failed: \(error)")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        TabView {
            PensTab(store: store).tabItem { Text("Pens") }
            BooksTab(store: store).tabItem { Text("Notebooks") }
            GeneralTab(store: store).tabItem { Text("General") }
            ReadingTab(store: store).tabItem { Text("Reading") }
        }
        .padding(16)
        .frame(width: 460, height: 420)
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
        VStack(alignment: .leading, spacing: 14) {
            Row("DAM") {
                TextField("https://dam.example.com", text: Binding(
                    get: { store.config.damHost ?? "" },
                    set: { store.config.damHost = $0.isEmpty ? nil : $0 }
                ), onCommit: { store.saveConfig() })
                .textFieldStyle(.roundedBorder)
            }
            Row("Key") {
                SecureField("pk_…", text: $store.damApiKey, onCommit: { store.saveDamKey() })
                    .textFieldStyle(.roundedBorder)
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

            if !roster.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(roster) { agent in
                        AgentRow(store: store, agent: agent,
                                 reads: store.config.damAgentId == agent.id)
                        if agent.id != roster.last?.id { Divider().opacity(0.4) }
                    }
                }
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            }

            // What the key can see and the roster has not taken yet.
            let spare = store.damAgents.filter { known in !roster.contains { $0.id == known.id } }
            HStack(spacing: 8) {
                if spare.isEmpty && store.damAgents.isEmpty {
                    // No listing yet: an id can still be typed, which is how the very first agent
                    // gets in when the key can list nothing.
                    TextField("agent-…", text: Binding(
                        get: { store.config.damAgentId ?? "" },
                        set: { store.config.damAgentId = $0.isEmpty ? nil : $0 }
                    ), onCommit: { store.saveConfig() })
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                } else {
                    Menu("Add an agent") {
                        ForEach(spare) { agent in
                            Button(agent.name) {
                                Task {
                                    await store.addToRoster(agent)
                                    if store.config.damAgentId == nil {
                                        store.config.damAgentId = agent.id
                                        store.saveConfig()
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: 140)
                    .disabled(spare.isEmpty)
                }
                Spacer()
            }

            if let status = store.damStatus {
                Hint(status)
            }
            Row("Wait before reading") {
                Stepper(value: $store.config.damQuietMinutes, in: 1...60, step: 1) {
                    Text("\(Int(store.config.damQuietMinutes)) min").font(.system(size: 11)).monospacedDigit()
                }
                .onChange(of: store.config.damQuietMinutes) { _ in store.saveConfig() }
            }
            Spacer()
            Hint("A page that has been still for this long is drawn, sent to the reader and read "
                 + "back as Markdown beside the strokes. The reader also proposes which agent "
                 + "should carry out each line the page asks for — so give the reading to an agent "
                 + "with nothing confidential behind it: it is the one looking at whatever the "
                 + "paper happens to say. The key needs the agents:operate scope for every agent "
                 + "here; it is kept in dam-key beside the config file, readable only by you.")
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

    private var asking: Bool { store.asking.contains(agent.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // One reader at a time, chosen here. A radio rather than a menu, because the point of
            // the choice is that everything else on this list is not it.
            Button {
                store.config.damAgentId = agent.id
                store.saveConfig()
            } label: {
                Image(systemName: reads ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(reads ? Ink.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Read pages with this agent")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name).font(.system(size: 12, weight: .medium))
                    if reads {
                        Text("reads pages")
                            .font(.system(size: 10))
                            .foregroundStyle(Ink.accent)
                    }
                }
                Text(asking ? "asking what it does…" : (agent.summary ?? "never asked"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(agent.summary == nil && !asking ? .tertiary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !agent.systems.isEmpty {
                    Text(agent.systems.joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            Button("Ask") { Task { await store.ask(agent.id) } }
                .font(.system(size: 10.5))
                .disabled(asking)
            Button {
                store.removeFromRoster(agent.id)
            } label: {
                Image(systemName: "minus.circle").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Take it off the list")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
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
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - window

public final class SettingsWindowController: NSWindowController {
    let store: SettingsStore

    public init(store: SettingsStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Brainio Pen Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(store: store))
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
