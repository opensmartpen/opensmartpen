import AppKit
import Combine
import Foundation
import PenBridgeCore

/// Everything the panel draws, derived from `PenSession` and `SyncCoordinator` and nothing else.
/// Both of those already publish an `onChange` closure; this turns those into one observable
/// snapshot so the view never reaches into the pen or the git layer itself.
///
/// Lives on the main thread: every caller (`SyncCoordinator.finish`, `PenSession`'s marshalled
/// SDK callbacks) is already there.
final class PanelModel: ObservableObject {
    /// What the header says, in the order the person cares about: a failure outranks a transfer,
    /// which outranks ordinary connected life.
    enum Status: Equatable {
        case asleep                      // the A1 powers itself off after five minutes: the usual state
        case bluetoothOff
        case connecting
        case copying(book: Int, of: Int, percent: Int)
        case failing(attempts: Int, nextTry: Date?, error: String)
        case writing(page: PageLabel)
        case connected
    }

    struct PendingRow: Identifiable, Equatable {
        let id: String
        let label: PageLabel
        /// Nil while the page is still being written: its timer restarts on every stroke, so a
        /// countdown there would tick backwards.
        let deadline: Date?
        let isLive: Bool
    }

    struct Publish: Equatable {
        let date: Date
        let commit: String?
        let pages: Int
    }

    @Published private(set) var status: Status = .asleep
    @Published private(set) var penName = ""
    @Published private(set) var battery: Battery?
    @Published private(set) var pending: [PendingRow] = []
    @Published private(set) var pagesOnPen: Int?
    @Published private(set) var lastPublish: Publish?
    @Published private(set) var isPublishing = false
    @Published private(set) var recent: [RecentPage] = []
    /// When the pen was last connected. The only honest thing the panel can say about writing it
    /// cannot see: an absent pen may hold pages, and nothing on this Mac can count them.
    @Published private(set) var lastSeen: Date?

    /// What the next stroke will be drawn as. The pen cannot be told a colour, so this is our
    /// state: chosen by tapping the paper controller or by clicking a swatch here, and read back
    /// out of the same append-only log that the renderer joins against.
    @Published private(set) var ink: InkColor = .black
    @Published private(set) var width: LineWidth = .default
    /// Hex values for the swatches, from the repo. A name with no hex is unmeasured, and the
    /// panel draws a hole rather than guessing at a colour.
    @Published private(set) var palette = Palette()
    /// The pen's own name, and the notebook records, so the panel can say what things are called.
    @Published private(set) var penDisplayName = "Pen"

    /// A notebook we think might be a fresh physical copy. Two pads of the same model report the
    /// same Ncode id, so this cannot be decided silently — a wrong guess merges two notebooks into
    /// one set of files and nobody notices.
    @Published private(set) var instanceQuestion: InstanceQuestion?

    struct InstanceQuestion: Equatable {
        let bookKey: String
        let title: String
        let at: Int
        let reason: InstanceSuspicion.Reason

        var why: String {
            switch reason {
            case .sequenceRestart: return "Writing started again at the front."
            case .longGap: return "Nothing written in it for a month."
            }
        }
    }

    func ask(_ suspicion: InstanceSuspicion, title: String) {
        instanceQuestion = InstanceQuestion(bookKey: suspicion.book, title: title,
                                            at: suspicion.at, reason: suspicion.reason)
    }

    /// Yes, this is a new copy. Everything written from this moment goes to a fresh directory and
    /// everything before it stays exactly where it is.
    func confirmNewNotebook() {
        guard let q = instanceQuestion, let live,
              let book = live.books.books.first(where: { $0.id == q.bookKey }) else { return }
        live.books.startInstance(of: book, at: q.at)
        instanceQuestion = nil
        refreshRecent()
    }

    func dismissNewNotebook() {
        guard let q = instanceQuestion else { return }
        live?.books.resolveInstanceQuestion(q.bookKey)
        instanceQuestion = nil
    }

    struct RecentPage: Identifiable, Equatable {
        let id: String
        let label: PageLabel
        /// The rendered page, when the processing side has made one. Nil means nothing to open yet.
        let file: URL?
        /// The paper's proportions, so a wide pad and a tall notebook are told apart at a glance
        /// without anyone having to pick a colour for either.
        var shape: KnownBooks.Shape = .page
    }

    struct Battery: Equatable {
        let percent: Int
        let charging: Bool
        let low: Bool
    }

    /// A page written within this many seconds counts as being written right now.
    private static let liveWindow: TimeInterval = 45

    /// Everything the model derives from. Absent in the design window, which sets the published
    /// properties directly instead — that is the whole of what "design mode" means here.
    struct Live {
        let session: PenSession
        let coordinator: SyncCoordinator
        let config: Config
        let books: BookRegistry
        let pens: PenRegistry
    }

    private let live: Live?
    private var lastPaletteLoad = Date.distantPast

    init(session: PenSession, coordinator: SyncCoordinator, config: Config,
         books: BookRegistry, pens: PenRegistry) {
        live = Live(session: session, coordinator: coordinator, config: config,
                    books: books, pens: pens)
    }

    /// A model with no pen and no repo behind it, for the design window.
    init(scenario: Scenario) {
        live = nil
        apply(scenario)
    }

    /// Recompute from live state. Called on every change and once a second while the panel is open,
    /// which is what keeps the countdowns moving.
    func refresh(now: Date = Date()) {
        guard let live else { return }   // design mode: the published values are the source
        let session = live.session, coordinator = live.coordinator
        let config = live.config, books = live.books
        penName = session.penName.isEmpty ? "Pen" : session.penName
        if session.isConnected { lastSeen = now }
        penDisplayName = live.pens.name(mac: config.penMac ?? "")

        // The palette is a file in the repo that a person edits by hand; re-reading it once a
        // second would be wasteful and once a launch would make an edit invisible.
        if now.timeIntervalSince(lastPaletteLoad) > 20 {
            lastPaletteLoad = now
            palette = Palette.load(root: config.repoURL)
        }
        if let mode = coordinator.modeLog?.current {
            ink = mode.ink
            width = mode.width
        }
        isPublishing = coordinator.isPublishing

        // Only while the pen is actually here. A percentage read hours ago looks live and is not,
        // and the macOS Bluetooth menu sets the convention: a battery for what is connected,
        // nothing at all for the rest.
        if let s = session.setting, session.isConnected {
            let pct = Int(s.battLevel)
            let charging = s.charging == .On
            battery = Battery(percent: pct, charging: charging,
                              low: pct <= config.lowBatteryPercent && !charging)
            let held = PenMemory.pages(usedPercent: Int(s.memoryUsed))
            pagesOnPen = held > 0 ? held : nil
        } else {
            battery = nil
            pagesOnPen = nil
        }

        let entries = coordinator.tracker.pending
        pending = entries.map { entry in
            let live = now.timeIntervalSince(entry.last) < Self.liveWindow
            return PendingRow(id: entry.page.description,
                              label: books.label(for: entry.page),
                              deadline: live ? nil : entry.deadline(window: coordinator.quietWindow),
                              isLive: live)
        }

        if let record = coordinator.lastPublish {
            lastPublish = Publish(date: record.date, commit: record.commit, pages: record.pages)
        }

        status = currentStatus(now: now)
    }

    private func currentStatus(now: Date) -> Status {
        guard let live else { return status }
        let session = live.session, coordinator = live.coordinator
        // A publish that keeps failing is the only thing worth displacing the pen's own state:
        // strokes are safe on disk, but nothing is leaving this Mac.
        if coordinator.consecutiveFailures >= 3, let error = coordinator.lastError {
            return .failing(attempts: coordinator.consecutiveFailures, nextTry: coordinator.nextRetryAt,
                            error: error)
        }
        switch session.state {
        case .bluetoothOff:
            return .bluetoothOff
        case .scanning:
            return .asleep
        case .connecting, .authorizing:
            return .connecting
        case .draining:
            if let d = session.drain {
                return .copying(book: d.index, of: d.count, percent: d.percent)
            }
            return .copying(book: 1, of: 1, percent: 0)
        case .ready:
            if let live = pending.first(where: \.isLive) {
                return .writing(page: live.label)
            }
            return .connected
        }
    }

    /// Only worth telling someone to wake the pen when there is nothing else on screen to do.
    var showsWakeHint: Bool {
        if case .asleep = status { return pending.isEmpty && recent.isEmpty }
        return false
    }

    /// Scanning the repo is too much for the one-second tick, so the recent list is rebuilt only
    /// when the panel is opened.
    func refreshRecent() {
        guard let books = live?.books else { return }
        recent = books.recentPages(limit: 4).map {
            RecentPage(id: $0.page.description, label: books.label(for: $0.page),
                       file: books.derivedFile(for: $0.page),
                       shape: books.record(for: $0.page)?.shape ?? .page)
        }
    }

    func open(_ page: RecentPage) {
        guard let file = page.file else { return }
        NSWorkspace.shared.open(file)
    }

    /// Set by the app delegate, which owns the window.
    var onShowLive: (() -> Void)?

    func showLive() { onShowLive?() }

    /// True while the panel is also open in its own window.
    @Published private(set) var isPinned = false

    var onTogglePin: (() -> Void)?

    func togglePin() { onTogglePin?() }

    /// Called by the app delegate when the pinned window opens or closes.
    func setPinned(_ pinned: Bool) { isPinned = pinned }

    // MARK: actions

    func publishNow() {
        live?.coordinator.publishAll()
    }

    func openNotes() {
        guard let repo = live?.config.repoURL else { return }
        NSWorkspace.shared.open(repo)
    }

    /// Set by the app delegate, which owns the window.
    var onOpenSettings: (() -> Void)?

    func openConfig() { onOpenSettings?() }

    /// Where the LaunchAgent sends stderr. Falls back to revealing the notes folder when the app
    /// was started by hand and the log is only on the terminal.
    func openLog() {
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PenBridge/penbridge.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        } else if let repo = live?.config.repoURL {
            NSWorkspace.shared.open(repo)
        }
    }

    /// Choose an ink or a width from the panel. Written to the same log a paper tap writes to —
    /// one file, one writer, and the renderer cannot tell which of the two a change came from.
    func choose(ink: InkColor) {
        guard let log = live?.coordinator.modeLog else { return }
        log.record(.ink(ink), at: Int(Date().timeIntervalSince1970 * 1000), source: .panel)
        refresh()
    }

    func choose(width: LineWidth) {
        guard let log = live?.coordinator.modeLog else { return }
        log.record(.width(width), at: Int(Date().timeIntervalSince1970 * 1000), source: .panel)
        refresh()
    }

    /// True when the swatch has no measured colour behind it. The panel draws a hole; nothing
    /// substitutes black here, because a hole is honest and a wrong colour is not.
    func isUnmeasured(_ ink: InkColor) -> Bool { palette.hex(for: ink) == nil }

    func pairDifferentPen() {
        live?.session.forgetPen()
    }

    // MARK: - design mode

    /// The states the panel can be in, as fixtures. Kept here rather than in the design window
    /// because `private(set)` on the published properties is file-scoped — and kept at all because
    /// several of these states are hard to reach on demand with real hardware: a failing push, a
    /// pen memory drain and a first run each take deliberate setup to see even once.
    enum Scenario: String, CaseIterable {
        case synced, writing, waiting, copying, failing, asleep, bluetoothOff, firstRun
        case newNotebook, unmeasuredInk

        var title: String {
            switch self {
            case .synced: return "All synced"
            case .writing: return "Writing"
            case .waiting: return "Waiting to sync"
            case .copying: return "Copying"
            case .failing: return "Can\u{2019}t sync"
            case .asleep: return "No pen"
            case .bluetoothOff: return "Bluetooth off"
            case .firstRun: return "First run"
            case .newNotebook: return "New notebook?"
            case .unmeasuredInk: return "Unmeasured ink"
            }
        }

        var note: String {
            switch self {
            case .synced: return "nothing pending, pen awake"
            case .writing: return "strokes arriving now"
            case .waiting: return "in the quiet window"
            case .copying: return "draining pen memory"
            case .failing: return "3+ push failures"
            case .asleep: return "the usual state"
            case .bluetoothOff: return "the one real blocker"
            case .firstRun: return "never paired"
            case .newNotebook: return "the one question we ask"
            case .unmeasuredInk: return "a colour with no hex"
            }
        }
    }

    private static func label(_ title: String, _ page: Int) -> PageLabel {
        PageLabel(title: title, detail: "page \(page)")
    }

    /// Fill the published properties by hand. Only ever called on a model built with `init(scenario:)`.
    func apply(_ scenario: Scenario) {
        let now = Date()
        let lamy = Self.label("LAMY digital paper", 6)
        let pad = Self.label("Ncode A4 pad", 3)

        penName = "Pen"
        penDisplayName = "Everyday"
        instanceQuestion = nil
        palette = Palette(ink: ["black": "#000000", "red": "#ff0200", "blue": "#00abeb",
                                "green": "#3cdd00", "grey": "#9e9e9e", "yellow": "#ffd400",
                                "orange": "#ff7a00", "purple": "#a21fd0", "navy": "#0033a0"])
        ink = .red
        width = .medium
        battery = Battery(percent: 16, charging: false, low: true)
        pagesOnPen = nil
        pending = []
        isPublishing = false
        lastPublish = Publish(date: now.addingTimeInterval(-260), commit: "4e35b96", pages: 2)
        recent = [
            RecentPage(id: "r1", label: Self.label("LAMY digital paper", 6), file: URL(fileURLWithPath: "/x"), shape: .pocket),
            RecentPage(id: "r2", label: Self.label("LAMY digital paper", 5), file: URL(fileURLWithPath: "/x"), shape: .pocket),
            RecentPage(id: "r3", label: Self.label("Ncode A4 pad", 3), file: nil, shape: .page),
            RecentPage(id: "r4", label: Self.label("Ncode A4 pad", 2), file: URL(fileURLWithPath: "/x"), shape: .page),
        ]

        switch scenario {
        case .synced:
            status = .connected
        case .writing:
            pending = [PendingRow(id: "p1", label: lamy, deadline: nil, isLive: true)]
            status = .writing(page: lamy)
        case .waiting:
            pending = [PendingRow(id: "p1", label: lamy, deadline: now.addingTimeInterval(372), isLive: false),
                       PendingRow(id: "p2", label: pad, deadline: now.addingTimeInterval(161), isLive: false)]
            status = .connected
        case .copying:
            pagesOnPen = 3
            status = .copying(book: 2, of: 5, percent: 62)
        case .failing:
            pending = [PendingRow(id: "p1", label: lamy, deadline: now, isLive: false),
                       PendingRow(id: "p2", label: pad, deadline: now, isLive: false)]
            recent = []
            status = .failing(attempts: 4, nextTry: now.addingTimeInterval(120),
                              error: "fatal: could not read from remote repository")
        case .asleep:
            status = .asleep
        case .bluetoothOff:
            battery = nil
            status = .bluetoothOff
        case .firstRun:
            battery = nil
            lastPublish = nil
            recent = []
            status = .asleep
        case .newNotebook:
            status = .connected
            instanceQuestion = InstanceQuestion(bookKey: "s3/o27/b450", title: "Ncode A4 pad",
                                                at: 0, reason: .sequenceRestart)
        case .unmeasuredInk:
            status = .connected
            ink = .white
        }
    }
}
