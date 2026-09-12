import AppKit
import PenBridgeCore
import SwiftUI

/// Everything that has a name or a number you might want to change.
///
/// The panel deliberately carries almost no words, which only works if there is somewhere else to
/// put them. This is that place: the pens and the notebooks, where naming actually happens, plus
/// the handful of settings that were previously only reachable by editing JSON by hand.
final class SettingsStore: ObservableObject {
    @Published var pens: [PenRecord] = []
    @Published var books: [BookRecord] = []
    @Published var config: Config
    @Published var palette = Palette()

    private let penRegistry: PenRegistry
    private let bookRegistry: BookRegistry
    private let configURL: URL
    /// Told when a setting that the running app cares about has changed.
    var onConfigChange: ((Config) -> Void)?

    init(pens: PenRegistry, books: BookRegistry, config: Config, configURL: URL) {
        penRegistry = pens
        bookRegistry = books
        self.config = config
        self.configURL = configURL
        reload()
    }

    func reload() {
        pens = penRegistry.pens
        books = bookRegistry.books.sorted { $0.title < $1.title }
        palette = Palette.load(root: config.repoURL)
    }

    func save(_ pen: PenRecord) {
        penRegistry.save(pen)
        reload()
    }

    func save(_ book: BookRecord) {
        bookRegistry.save(book)
        reload()
    }

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
                Picker("", selection: binding(\.width)) {
                    ForEach(LineWidth.allCases, id: \.rawValue) { w in
                        Text(w.rawValue.capitalized).tag(w)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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

private struct InkPicker: View {
    @Binding var selection: InkColor
    let palette: Palette

    var body: some View {
        HStack(spacing: 5) {
            ForEach(InkColor.allCases, id: \.rawValue) { colour in
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
                Hint("The title is yours to change at any time. The folder is fixed when a notebook "
                     + "is first seen, because it is also where every rendered page of it lives.")
                ForEach(store.books, id: \.slug) { book in
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
                Text("pages/\(book.slug)/").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
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
                Text(store.config.repoPath).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                Spacer()
                Button("Reveal") { NSWorkspace.shared.open(store.config.repoURL) }
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
            Toggle("Clear a notebook from the pen once it is synced",
                   isOn: $store.config.deleteFromPenAfterPublish)
                .onChange(of: store.config.deleteFromPenAfterPublish) { _ in store.saveConfig() }
            Spacer()
            Hint("Colours and line widths live in palette.json in the notes repo, so PenBridge and "
                 + "the renderer cannot disagree about what red looks like.")
        }
        .padding(.top, 4)
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

final class SettingsWindowController: NSWindowController {
    let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "PenBridge Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(store: store))
        window.setFrameAutosaveName("penbridge-settings")
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        store.reload()
        super.showWindow(sender)
    }
}
