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

    struct RecentPage: Identifiable, Equatable {
        let id: String
        let label: PageLabel
        /// The rendered page, when the processing side has made one. Nil means nothing to open yet.
        let file: URL?
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
    }

    private let live: Live?

    init(session: PenSession, coordinator: SyncCoordinator, config: Config, books: BookRegistry) {
        live = Live(session: session, coordinator: coordinator, config: config, books: books)
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
                       file: books.derivedFile(for: $0.page))
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

    func openConfig() {
        NSWorkspace.shared.open(Config.defaultLocation)
    }

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
        battery = Battery(percent: 16, charging: false, low: true)
        pagesOnPen = nil
        pending = []
        isPublishing = false
        lastPublish = Publish(date: now.addingTimeInterval(-260), commit: "4e35b96", pages: 2)
        recent = [
            RecentPage(id: "r1", label: Self.label("LAMY digital paper", 6), file: URL(fileURLWithPath: "/x")),
            RecentPage(id: "r2", label: Self.label("LAMY digital paper", 5), file: URL(fileURLWithPath: "/x")),
            RecentPage(id: "r3", label: Self.label("Ncode A4 pad", 3), file: nil),
            RecentPage(id: "r4", label: Self.label("Ncode A4 pad", 2), file: URL(fileURLWithPath: "/x")),
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
        }
    }
}
