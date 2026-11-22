import AppKit
import OpenSmartPenCore
import SwiftUI

/// The updater, as the About tab uses it. Closures, because the updater is in the layer above.
public struct UpdateControls {
    public var check: () -> Void
    public var isAutomatic: () -> Bool
    public var setAutomatic: (Bool) -> Void

    public init(check: @escaping () -> Void, isAutomatic: @escaping () -> Bool,
                setAutomatic: @escaping (Bool) -> Void) {
        self.check = check
        self.isAutomatic = isAutomatic
        self.setAutomatic = setAutomatic
    }
}

/// What the About tab says about this build, and where its files are. Handed in by the app,
/// because the version and the SDK are facts of the layer above this one.
public struct AppInfo {
    public var name = "Open Smart Pen"
    public var version: String
    public var sdk: String
    public var configURL: URL
    public var logURL: URL
    public var websiteURL = URL(string: "https://opensmartpen.org/")!
    public var sourceURL = URL(string: "https://github.com/opensmartpen/opensmartpen")!
    /// The source of the pen SDK this build links, at the version `Package.swift` pins. The built
    /// app is GPL-3.0 because of it, and the GPL asks that a copy says where that source is.
    public var sdkSourceURL = URL(string: "https://github.com/NeoSmartpen/iOS-SDK3.0/tree/1.1.5")!
    /// The license texts `make-app.sh` puts in the bundle. Nil for a bare binary, which has none.
    /// The random id this install reports under. Empty in the design window, which reports nothing.
    public var installId = ""
    public var licensesURL: URL? = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }()

    /// Nil for a build with no update feed: a development build, or a bare binary.
    public var updates: UpdateControls?

    public init(version: String, sdk: String, configURL: URL, logURL: URL) {
        self.version = version
        self.sdk = sdk
        self.configURL = configURL
        self.logURL = logURL
    }
}

/// How the uploads are going, as the Sync tab shows it. Set by the app on every change.
public struct SyncStatus: Equatable {
    public var uploading = false
    /// Pages written and not yet sent.
    public var pending = 0
    public var lastUpload: Date?
    public var lastFiles = 0
    /// Why the last attempt failed, or nil when it did not.
    public var error: String?
    /// The agents that keep a record, by name. Empty when none is connected.
    public var agents: [String] = []
    /// What a person gives their agent to set it up.
    public var agentSentence = ""

    public init() {}
}

/// Everything that has a name or a number you might want to change.
///
/// The panel deliberately carries almost no words, which only works if there is somewhere else to
/// put them. This is that place: the pens and the notebooks, where naming happens, the bucket the
/// pages are copied to, and the handful of numbers the app runs on.
public final class SettingsStore: ObservableObject {
    @Published var pens: [PenRecord] = []
    @Published var books: [BookRecord] = []
    @Published var config: Config
    @Published var palette = Palette()

    /// Looking for a new pen, after "Add pen…".
    @Published var adding = false
    /// MACs of the pens connected right now.
    @Published var connected: Set<String> = []

    /// The bucket as it is being typed. Nothing here takes effect until Connect has proved it:
    /// a bucket name applied one letter at a time is a dozen uploads to buckets that do not exist.
    @Published var s3Draft: S3Settings
    @Published var s3SecretDraft: String
    @Published var s3State: S3State = .idle
    @Published public var sync = SyncStatus()
    /// A settings file that could not be written. Shown until a save works.
    @Published var problem: String?

    enum S3State: Equatable {
        case idle
        case checking
        case failed(String)
    }

    let info: AppInfo
    private let penRegistry: PenRegistry
    private let bookRegistry: BookRegistry
    private let configURL: URL
    private let secretURL: URL
    private var savedSecret: String
    /// The config as it was last written, to say which setting a save changed.
    private var lastSaved: Config
    /// The running pens, for pairing. Nil in the design window, which has no pens.
    private weak var link: PenLink?
    private var pairedMacs: [String] = []
    /// Told when a setting that the running app cares about has changed.
    public var onConfigChange: ((Config) -> Void)?
    /// Told when a pen or a notebook was renamed: a changed file with no page to ride along with.
    public var onRecordsChange: (() -> Void)?
    public var onSyncNow: (() -> Void)?

    public init(pens: PenRegistry, books: BookRegistry, config: Config, configURL: URL,
                info: AppInfo, link: PenLink? = nil, secretURL: URL = S3Secret.location) {
        penRegistry = pens
        bookRegistry = books
        self.config = config
        lastSaved = config
        self.configURL = configURL
        self.info = info
        self.link = link
        self.secretURL = secretURL
        savedSecret = S3Secret.read(at: secretURL) ?? ""
        s3Draft = config.s3
        s3SecretDraft = savedSecret
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

    func addPen() {
        Telemetry.event("ui.pen.add", ["ui.source": "settings"])
        link?.addPen()
        readLink()
    }

    func cancelAdding() {
        Telemetry.event("ui.pen.add_cancelled", ["ui.source": "settings"])
        link?.cancelAdding()
        readLink()
    }

    func forget(_ pen: PenRecord) {
        Telemetry.event("ui.pen.forget", ["pen.mac": .string(pen.mac)])
        link?.forgetPen(mac: pen.mac)
        linkChanged()
    }

    public func reload() {
        // Only the pens this Mac accepts. A forgotten pen's record stays in the notes folder for
        // the strokes it already wrote, but there is nothing left to set on it here.
        let paired = Set(pairedMacs)
        pens = link == nil ? penRegistry.pens : penRegistry.pens.filter { paired.contains($0.mac) }
        books = bookRegistry.books.sorted { $0.title < $1.title }
        palette = Palette.load(root: config.dataURL)
    }

    func save(_ pen: PenRecord) {
        // Which fields changed, and the new mode, ink and width. Never the name.
        if let before = penRegistry.record(mac: pen.mac) {
            var attributes: [String: TelemetryValue] = ["pen.mac": .string(pen.mac)]
            if before.name != pen.name { attributes["pen.renamed"] = true }
            if before.mode != pen.mode { attributes["pen.mode"] = .string(pen.mode.rawValue) }
            if before.ink != pen.ink { attributes["pen.ink"] = .string(pen.ink.rawValue) }
            if before.width != pen.width { attributes["pen.width"] = .string(pen.width.rawValue) }
            Telemetry.event("ui.pen.edited", attributes)
        }
        penRegistry.save(pen)
        reload()
        onRecordsChange?()
    }

    func save(_ book: BookRecord) {
        Telemetry.event("ui.book.renamed", ["book.surface": .string(book.folder.surface)])
        bookRegistry.save(book)
        reload()
        onRecordsChange?()
    }

    // MARK: the bucket

    /// A bucket is connected: the saved settings and the saved secret are a whole account.
    var s3Connected: Bool { config.s3Account(secret: savedSecret) != nil }

    /// The fields say something other than what is saved.
    var s3Edited: Bool { s3Draft != config.s3 || s3SecretDraft != savedSecret }

    /// Prove what is in the fields by asking the bucket one question, and only then keep it.
    ///
    /// The test is the save. A bucket that never answered is not a setting, it is a guess. The
    /// test writes nothing: the bucket belongs to its owner, and a test file in it is litter.
    @MainActor
    func connectS3() async {
        guard let account = S3Account(settings: s3Draft, secret: s3SecretDraft) else {
            s3State = .failed("A bucket, an access key ID and a secret access key are needed.")
            Telemetry.event("bucket.connect", ["bucket.result": "incomplete"], level: .warn)
            return
        }
        // Whose S3 it is, as one of two words. Not the address.
        let service: TelemetryValue = account.endpoint.host?.hasSuffix("amazonaws.com") == true ? "aws" : "other"
        s3State = .checking
        let client = S3Client(account: account)
        let outcome: Result<Void, Error> = await Task.detached {
            Result { try client.check() }
        }.value
        switch outcome {
        case .success:
            do {
                try S3Secret.write(s3SecretDraft, to: secretURL)
                savedSecret = S3Secret.read(at: secretURL) ?? ""
                config.s3 = s3Draft
                s3State = .idle
                Telemetry.event("bucket.connect", ["bucket.result": "connected", "bucket.service": service,
                                                   "bucket.has_folder": .bool(!s3Draft.prefix.isEmpty)])
                saveConfig()
            } catch {
                s3State = .failed("The secret could not be saved: \(error.localizedDescription)")
                Telemetry.event("bucket.connect", ["bucket.result": "secret not saved", "bucket.service": service],
                                level: .error)
            }
        case let .failure(error):
            s3State = .failed(error.localizedDescription)
            // How the bucket said no: the status and the service's own code, which name nothing.
            var attributes: [String: TelemetryValue] = ["bucket.result": "refused", "bucket.service": service]
            switch error as? S3Error {
            case let .refused(status, code, _):
                attributes["http.response.status_code"] = .int(status)
                if let code { attributes["bucket.error_code"] = .string(code) }
            case .unreachable:
                attributes["bucket.result"] = "unreachable"
            case nil:
                break
            }
            Telemetry.event("bucket.connect", attributes, level: .warn)
        }
    }

    /// Stop uploading. Nothing in the bucket is touched, and nothing on this Mac either.
    func disconnectS3() {
        Telemetry.event("bucket.disconnected")
        try? S3Secret.write(nil, to: secretURL)
        savedSecret = ""
        config.s3 = S3Settings()
        s3Draft = S3Settings()
        s3SecretDraft = ""
        s3State = .idle
        saveConfig()
    }

    /// Put the fields back to what is saved.
    func revertS3() {
        s3Draft = config.s3
        s3SecretDraft = savedSecret
        s3State = .idle
    }

    /// The telemetry setting was changed outside this window, by the notice. Without this, the
    /// next save from here would write the old value back.
    public func adopt(telemetry: TelemetrySettings) {
        config.telemetry = telemetry
        lastSaved.telemetry = telemetry
    }

    /// The start at login was chosen outside this window, in the first window. The same reason.
    public func adopt(startAtLogin: Bool) {
        config.startAtLogin = startAtLogin
        lastSaved.startAtLogin = startAtLogin
    }

    func syncNow() {
        Telemetry.event("ui.sync_now", ["ui.source": "settings"])
        onSyncNow?()
    }

    // MARK: saving

    func saveConfig() {
        do {
            // Which pens are paired is the pen session's to write, and it can change while this
            // window is open. The file's list wins over the copy this window opened with.
            if let onDisk = try? Config.loadOrCreate(at: configURL) {
                config.pairedPens = onDisk.pairedPens
            }
            try config.save(to: configURL)
            problem = nil
            reportChanges(from: lastSaved, to: config)
            lastSaved = config
            onConfigChange?(config)
        } catch {
            Log.error("saving config failed: \(error)")
            problem = "The settings could not be saved: \(error.localizedDescription)"
        }
    }

    /// One event for each setting a save changed, with its new value. The bucket is not here:
    /// connecting one has an event of its own, and its fields are private.
    private func reportChanges(from old: Config, to new: Config) {
        func changed(_ name: String, _ value: TelemetryValue) {
            Telemetry.event("ui.setting.changed", ["setting.name": .string(name), "setting.value": value])
        }
        if old.startAtLogin != new.startAtLogin { changed("startAtLogin", .bool(new.startAtLogin)) }
        if old.quietSeconds != new.quietSeconds { changed("quietSeconds", .double(new.quietSeconds)) }
        if old.deleteFromPenAfterPublish != new.deleteFromPenAfterPublish {
            changed("deleteFromPenAfterPublish", .bool(new.deleteFromPenAfterPublish))
        }
        if old.lowBatteryPercent != new.lowBatteryPercent { changed("lowBatteryPercent", .int(new.lowBatteryPercent)) }
        if old.memoryWarnPercent != new.memoryWarnPercent { changed("memoryWarnPercent", .int(new.memoryWarnPercent)) }
        // Turning telemetry on is reported. Turning it off is not: off means nothing more is sent.
        if !old.telemetry.enabled, new.telemetry.enabled { changed("telemetry", true) }
    }
}

// MARK: - tabs

public enum SettingsTab: Int, CaseIterable {
    case pens, books, sync, general, about

    var title: String {
        switch self {
        case .pens: return "Pens"
        case .books: return "Notebooks"
        case .sync: return "Sync"
        case .general: return "General"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .pens: return "pencil.tip"
        case .books: return "book.closed"
        case .sync: return "arrow.triangle.2.circlepath"
        case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

/// One width for every tab. The height is the tab's own, up to a limit: a tab with three rows is
/// not drawn above a field of empty grey, and a tab with five pens scrolls.
private let pageWidth: CGFloat = 620
private let pageMaxHeight: CGFloat = 720

/// The ground every tab stands on: a grouped form, the way System Settings draws one. Labels on
/// the left, values on the right, at the system's own sizes — nothing here is set in 10-point type.
private struct Page<Content: View>: View {
    @ObservedObject var store: SettingsStore
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form {
            if let problem = store.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Ink.critical)
                }
            }
            content()
        }
        .formStyle(.grouped)
        .frame(width: pageWidth)
        .frame(maxHeight: pageMaxHeight)
    }
}

// MARK: - pens

private struct PensTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Page(store: store) {
            ForEach(store.pens, id: \.slug) { pen in
                PenSection(pen: pen, palette: store.palette, connected: store.connected.contains(pen.mac),
                           save: { store.save($0) }, forget: { store.forget(pen) })
            }
            Section {
                // Pairing is the one thing here that waits on the hardware, so it says what it is
                // waiting for. Only one new pen is taken, and only while this is looking.
                if store.adding {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for a new pen. Switch it on near this Mac.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { store.cancelAdding() }
                    }
                } else {
                    HStack {
                        Text(store.pens.isEmpty ? "No pen yet" : "Another pen")
                        Spacer()
                        Button("Add Pen…") { store.addPen() }
                    }
                }
            }
        }
    }
}

private struct PenSection: View {
    let pen: PenRecord
    let palette: Palette
    let connected: Bool
    let save: (PenRecord) -> Void
    let forget: () -> Void
    @State private var confirmingForget = false

    var body: some View {
        Section {
            LiveField(label: "Name", value: pen.name) { name in
                var updated = pen
                updated.name = name
                save(updated)
            }
            // The one thing about a pen that its ink does not say: whether its strokes are the
            // writing, or go over it.
            LabeledContent("Used for") {
                Segments(selection: binding(\.mode), choices: PenMode.allCases) { mode in
                    Text(mode.rawValue.capitalized)
                }
            }
            // The same marks as the panel, in the same order: the inks, then the three widths.
            // Somebody who has picked red in the menubar should find red here without reading.
            // Three widths, because the paper strip has three buttons. `LineWidth.default` is the
            // state before anything has been tapped, not a fourth width you can pick.
            LabeledContent("Ink") {
                HStack(spacing: 14) {
                    InkPicker(selection: binding(\.ink), palette: palette)
                    HStack(spacing: 4) {
                        ForEach([LineWidth.thin, .medium, .thick], id: \.rawValue) { weight in
                            WidthMark(weight: weight, selected: weight == pen.width) {
                                var updated = pen
                                updated.width = weight
                                save(updated)
                            }
                        }
                    }
                }
            }
            LabeledContent("Address") {
                Text(pen.mac).font(.callout.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Remove…") { confirmingForget = true }
            }
        } header: {
            HStack(spacing: 6) {
                Text(pen.name)
                Spacer()
                StatusMark(on: connected, text: connected ? "Connected" : "Not connected")
            }
        }
        .confirmationDialog("Remove \(pen.name)?", isPresented: $confirmingForget) {
            Button("Remove", role: .destructive, action: forget)
        } message: {
            Text("This Mac stops syncing from it. Notes it already wrote stay. Add it again to use it.")
        }
    }

    private func binding<V>(_ path: WritableKeyPath<PenRecord, V>) -> Binding<V> {
        Binding(get: { pen[keyPath: path] },
                set: { new in var u = pen; u[keyPath: path] = new; save(u) })
    }
}

/// One choice out of a few, drawn the way the system draws a segmented control, in the same
/// greys as the width marks beside it.
private struct Segments<Value: Hashable, Label: View>: View {
    @Binding var selection: Value
    let choices: [Value]
    @ViewBuilder let label: (Value) -> Label

    var body: some View {
        HStack(spacing: 0) {
            ForEach(choices, id: \.self) { choice in
                let on = selection == choice
                Button { selection = choice } label: {
                    label(choice)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(on ? Color(nsColor: .controlColor) : .clear)
                            .shadow(color: .black.opacity(on ? 0.18 : 0), radius: 1, y: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
        .frame(width: CGFloat(choices.count) * 96)
    }
}

/// The dot and the word at the right of a section's title: is this thing connected or not.
private struct StatusMark: View {
    let on: Bool
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(on ? Ink.done : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
            Text(text).font(.callout).fontWeight(.regular).foregroundStyle(.secondary)
        }
    }
}

private struct InkPicker: View {
    @Binding var selection: InkColor
    let palette: Palette

    var body: some View {
        HStack(spacing: 4) {
            ForEach(choices, id: \.rawValue) { colour in
                if let fill = Color(inkHex: palette.hex(for: colour)) {
                    InkDot(colour: fill, selected: selection == colour) { selection = colour }
                        .help(colour.rawValue.capitalized)
                } else {
                    // An ink with no colour behind it has nothing to fill a dot with.
                    Button { selection = colour } label: {
                        Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.5]))
                            .foregroundStyle(selection == colour ? .primary : .tertiary)
                            .frame(width: 16, height: 16).padding(2)
                    }
                    .buttonStyle(.plain)
                    .help("\(colour.rawValue.capitalized): no colour assigned")
                }
            }
        }
    }

    /// A pen may still name an ink the repo has stopped offering. Show it rather than silently
    /// dropping it, so the setting is visible and can be changed.
    private var choices: [InkColor] {
        palette.offered.contains(selection) ? palette.offered : palette.offered + [selection]
    }
}

// MARK: - notebooks

private struct BooksTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Page(store: store) {
            if store.books.isEmpty {
                Section {
                    Text("No notebook yet. One appears here the first time a pen writes in it.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(store.books, id: \.folder) { book in
                Section {
                    LiveField(label: "Title", value: book.title) { title in
                        var updated = book
                        updated.title = title
                        store.save(updated)
                    }
                    LabeledContent("Paper", value: paper(book))
                    LabeledContent("Folder") {
                        Text(book.folder.name).font(.callout.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Show") {
                            NSWorkspace.shared.open(store.config.dataURL
                                .appendingPathComponent(book.folder.relativePath))
                        }
                    }
                } header: {
                    Text(book.title)
                }
            }
            if !store.books.isEmpty {
                Section {} footer: {
                    Note("A title can change at any time, and nothing moves when it does. "
                         + "The folder name is fixed when the notebook is first seen.")
                }
            }
        }
    }

    private func paper(_ book: BookRecord) -> String {
        guard let w = book.widthMM, let h = book.heightMM else { return "Size not recorded" }
        return String(format: "%.0f × %.0f mm", w, h)
    }
}

// MARK: - sync

/// Where the pages go. One bucket, proved by asking it, and the two rules for when.
private struct SyncTab: View {
    @State private var agentCopied = false
    @ObservedObject var store: SettingsStore
    @State private var confirmingDisconnect = false

    private static let waits: [Double] = [10, 30, 60, 300, 600]

    var body: some View {
        Page(store: store) {
            Section {
                TextField("Bucket", text: $store.s3Draft.bucket, prompt: Text("my-notes"))
                TextField("Region", text: $store.s3Draft.region, prompt: Text("us-east-1"))
                TextField("Access key ID", text: $store.s3Draft.accessKeyId, prompt: Text("AKIA…"))
                SecureField("Secret access key", text: $store.s3SecretDraft)
                TextField("Folder in the bucket", text: $store.s3Draft.prefix, prompt: Text("None"))
                TextField("Endpoint", text: $store.s3Draft.endpoint, prompt: Text("Amazon S3"))
                connection
            } header: {
                HStack(spacing: 6) {
                    Text("S3 bucket")
                    Spacer()
                    StatusMark(on: store.s3Connected,
                               text: store.s3Connected ? "Connected" : "Not connected")
                }
            } footer: {
                Note("Every page is kept on this Mac as its strokes and a PNG, and copied to this bucket. Nothing in the "
                     + "bucket is deleted, and the only thing read from it is the transcript of a "
                     + "page you open. Fill in Endpoint only for a service other than Amazon S3, "
                     + "such as Cloudflare R2 or MinIO.")
            }
            .autocorrectionDisabled()

            Section {
                LabeledContent(store.sync.agents.isEmpty ? "Not connected"
                               : store.sync.agents.joined(separator: ", ")) {
                    Button(agentCopied ? "Copied" : "Copy Instructions") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.sync.agentSentence, forType: .string)
                        Telemetry.event("ui.agent.copy_instructions", ["ui.source": "settings"])
                        agentCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { agentCopied = false }
                    }
                    .disabled(store.sync.agentSentence.isEmpty)
                }
            } header: {
                Text("Agent")
            } footer: {
                Note("Open Smart Pen does not turn handwriting into text. An agent of your choice "
                     + "does, for example Claude Code or Codex. To set up a new agent with Claude, "
                     + "use the panel in the menu bar. For an agent you have, copy the instructions "
                     + "and paste them into it. "
                     + "An agent is connected when it has written its name beside your pages.")
            }

            Section {
                Picker("Upload after", selection: $store.config.quietSeconds) {
                    ForEach(waits, id: \.self) { Text(Self.wait($0)).tag($0) }
                }
                .onChange(of: store.config.quietSeconds) { _ in store.saveConfig() }
                Toggle("Free the pen's memory once its pages are synced",
                       isOn: $store.config.deleteFromPenAfterPublish)
                    .onChange(of: store.config.deleteFromPenAfterPublish) { _ in store.saveConfig() }
                LabeledContent("Last upload") {
                    Text(lastUpload).foregroundStyle(.secondary)
                    Button("Sync Now") { store.syncNow() }
                        .disabled(!store.s3Connected || store.sync.uploading)
                }
            } header: {
                Text("Uploads")
            } footer: {
                Note("The pen keeps its own copy of what you write while it is away from this "
                     + "Mac. Freeing its memory deletes that copy after the pages are safe here "
                     + "and in the bucket. Your notes are not deleted.")
            }
        }
        .confirmationDialog("Disconnect the bucket?", isPresented: $confirmingDisconnect) {
            Button("Disconnect", role: .destructive) { store.disconnectS3() }
        } message: {
            Text("Uploads stop and the keys are removed from this Mac. "
                 + "The files in the bucket and the notes on this Mac stay.")
        }
    }

    /// The waits on offer, plus whatever a hand-edited config says if it is none of them.
    private var waits: [Double] {
        Self.waits.contains(store.config.quietSeconds) ? Self.waits
            : (Self.waits + [store.config.quietSeconds]).sorted()
    }

    private static func wait(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds)) seconds with no pen activity"
            : "\(Int(seconds / 60)) minute\(seconds >= 120 ? "s" : "") with no pen activity"
    }

    /// One line that says where things stand, and the one button that moves them on.
    @ViewBuilder private var connection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch store.s3State {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Testing the connection…").foregroundStyle(.secondary)
            case let .failed(why):
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Ink.critical)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            case .idle:
                if let error = store.sync.error, store.s3Connected, !store.s3Edited {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Ink.critical)
                        .fixedSize(horizontal: false, vertical: true)
                } else if store.s3Connected, !store.s3Edited {
                    // The header says it is connected. This says to where, in one piece, which
                    // the five fields above do not.
                    (Text("Pages go to ") + Text(destination).font(.callout.monospaced()))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else if store.s3Connected {
                    Text("Not saved yet").foregroundStyle(.secondary)
                } else {
                    Text("Notes stay on this Mac until a bucket is connected.")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if store.s3Connected, !store.s3Edited {
                Button("Disconnect…") { confirmingDisconnect = true }
            } else {
                if store.s3Connected { Button("Revert") { store.revertS3() } }
                Button(store.s3Connected ? "Save" : "Connect") {
                    Task { await store.connectS3() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.s3State == .checking)
            }
        }
    }

    private var destination: String {
        let folder = store.config.s3.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return folder.isEmpty ? store.config.s3.bucket : "\(store.config.s3.bucket)/\(folder)"
    }

    private var lastUpload: String {
        if store.sync.uploading { return "Uploading…" }
        if !store.s3Connected { return "No bucket connected" }
        guard let date = store.sync.lastUpload else {
            return store.sync.pending > 0 ? "\(store.sync.pending) page(s) waiting" : "Nothing yet"
        }
        let time = date.formatted(date: .omitted, time: .shortened)
        let files = store.sync.lastFiles
        return files > 0 ? "\(time), \(files) file\(files == 1 ? "" : "s")" : "\(time), nothing new"
    }
}

// MARK: - general

private struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    @State private var showsFolderInfo = false
    @State private var showsWhatIsSent = false
    @State private var copied = false

    var body: some View {
        Page(store: store) {
            Section {
                LabeledContent {
                    // With a limit, because a row whose value is too wide stops being a row: the
                    // form stacks it under its label.
                    Text((store.config.dataURL.path as NSString).abbreviatingWithTildeInPath)
                        .font(.callout.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 250, alignment: .trailing)
                        .help(store.config.dataURL.path)
                    Button("Show in Finder") {
                        Telemetry.event("ui.notes.opened", ["ui.source": "settings"])
                        NSWorkspace.shared.open(store.config.dataURL)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Notes folder")
                        // What the folder is, for a person who asks. Not a line under the row,
                        // which each person read each time.
                        Button { showsFolderInfo.toggle() } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("What is kept here")
                            .popover(isPresented: $showsFolderInfo, arrowEdge: .bottom) {
                                Text("Everything the pens write is kept here, outside the app, so the app "
                                     + "can be deleted and installed again without losing a page.")
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(14)
                                    .frame(width: 300)
                            }
                    }
                }
            }

            Section {
                Toggle("Start at login", isOn: $store.config.startAtLogin)
                    .onChange(of: store.config.startAtLogin) { _ in store.saveConfig() }
            }

            Section {
                Toggle(isOn: $store.config.telemetry.enabled) {
                    HStack(spacing: 8) {
                        Text("Help us improve")
                        // The same words the first window has, one click from the switch.
                        Button("What is sent") { showsWhatIsSent.toggle() }
                            .buttonStyle(.link)
                            .font(.callout)
                            .popover(isPresented: $showsWhatIsSent, arrowEdge: .bottom) { WhatIsSent() }
                    }
                }
                .onChange(of: store.config.telemetry.enabled) { _ in store.saveConfig() }
            } footer: {
                if TelemetryPlan.builtInIsLocal {
                    Note("The project has no server for this yet. With this on, the app sends to "
                         + "a collector on this Mac, at \(TelemetryPlan.builtInEndpoint), unless the "
                         + "config names another.")
                }
            }

            Section("Troubleshooting") {
                LabeledContent("Log") {
                    Button("Open") {
                        Telemetry.event("ui.log.opened", ["ui.source": "settings"])
                        NSWorkspace.shared.open(store.info.logURL)
                    }
                        .disabled(!FileManager.default.fileExists(atPath: store.info.logURL.path))
                }
                LabeledContent("Settings file") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.info.configURL])
                    }
                }
                if !store.info.installId.isEmpty {
                    LabeledContent("Install ID") {
                        Text(store.info.installId).font(.callout.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                            .help("A random id for this install. Give it to the makers when you report a problem.")
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(store.info.installId, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - about

private struct AboutTab: View {
    @ObservedObject var store: SettingsStore
    @State private var checksAutomatically = false

    var body: some View {
        Page(store: store) {
            Section {
                VStack(spacing: 6) {
                    // Run as a bare binary there is no icon, only the Finder's stand-in for one.
                    if Bundle.main.bundlePath.hasSuffix(".app") {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable().frame(width: 84, height: 84)
                    }
                    Text(store.info.name).font(.title2.weight(.semibold))
                    Text("Version \(store.info.version)").foregroundStyle(.secondary)
                    Text("You write. Your agent acts.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            // Always there, so the window is the same in each build. A build with no address
            // to get updates from, such as one made from the source, shows the two rows greyed.
            Section {
                Toggle("Update automatically", isOn: $checksAutomatically)
                    .onChange(of: checksAutomatically) { store.info.updates?.setAutomatic($0) }
                LabeledContent("Updates") {
                    Button("Check for Updates…") { store.info.updates?.check() }
                }
            } footer: {
                if store.info.updates == nil {
                    Note("This build does not update itself.")
                }
            }
            .disabled(store.info.updates == nil)
            .onAppear { checksAutomatically = store.info.updates?.isAutomatic() ?? false }
            Section {
                LabeledContent("Website") {
                    Link("opensmartpen.org", destination: store.info.websiteURL)
                }
                LabeledContent("Source") {
                    Link("github.com/opensmartpen/opensmartpen", destination: store.info.sourceURL)
                }
                // Only a packaged app carries the texts, so only a packaged app offers them. They
                // name each part the app contains and its license.
                if let licenses = store.info.licensesURL {
                    LabeledContent("Licenses") {
                        Button("Show") { NSWorkspace.shared.open(licenses) }
                    }
                }
            } footer: {
                Text("© Apoco s.r.o.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 6)
            }
        }
    }
}

// MARK: - pieces

/// The sentence under a section. Set from the left like everything above it: a grouped form
/// sets a footer from the right, which reads as a caption that has come loose.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A text field that keeps what you type a moment after you stop typing. Nothing here is worth a
/// Save button, and nothing here should need the Return key — that is a rule somebody has to be
/// told, and nobody is.
private struct LiveField: View {
    let label: String
    let value: String
    let commit: (String) -> Void
    @State private var text = ""
    @State private var pending: DispatchWorkItem?

    var body: some View {
        TextField(label, text: $text)
            .onAppear { text = value }
            .onChange(of: text) { _ in
                pending?.cancel()
                let work = DispatchWorkItem { keep() }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
            }
            .onSubmit { pending?.cancel(); keep() }
            .onDisappear { pending?.cancel(); keep() }
    }

    /// An emptied field is not a name. It is left alone until something is typed in it.
    private func keep() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != value else { return }
        commit(trimmed)
    }
}

// MARK: - window

/// A settings window the way macOS draws one: the tabs are the toolbar, and the title is the tab.
public final class SettingsWindowController: NSWindowController {
    let store: SettingsStore
    private let tabs = SettingsTabs()

    public init(store: SettingsStore, tab: SettingsTab = .pens) {
        self.store = store
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let page: NSViewController
            switch tab {
            case .pens: page = Self.host(PensTab(store: store))
            case .books: page = Self.host(BooksTab(store: store))
            case .sync: page = Self.host(SyncTab(store: store))
            case .general: page = Self.host(GeneralTab(store: store))
            case .about: page = Self.host(AboutTab(store: store))
            }
            let item = NSTabViewItem(viewController: page)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = tab.rawValue
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: pageWidth, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.toolbarStyle = .preference
        window.title = "Open Smart Pen Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = tabs
        window.center()
        window.setFrameAutosaveName("opensmartpen-settings-2")
        super.init(window: window)
        // Only while the window is on screen, so that only a person's choice is reported.
        tabs.onSelect = { [weak self] in
            guard self?.window?.isVisible == true else { return }
            self?.reportTab()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A tab that tells the window how tall it is, so the window fits it, and follows it when a
    /// pen is added or an error line appears.
    private static func host<V: View>(_ view: V) -> NSViewController {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        return host
    }

    public func select(_ tab: SettingsTab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
    }

    /// Which tab is on screen, for telemetry: said each time the window is shown or the tab changes.
    private func reportTab() {
        guard let tab = SettingsTab(rawValue: tabs.selectedTabViewItemIndex) else { return }
        Telemetry.event("ui.settings.tab", ["settings.tab": .string("\(tab)")])
    }

    public override func showWindow(_ sender: Any?) {
        store.reload()
        super.showWindow(sender)
        reportTab()
    }
}

/// The tabs, and the one thing the window wants to know about them: that another one was chosen.
private final class SettingsTabs: NSTabViewController {
    var onSelect: (() -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelect?()
    }
}
