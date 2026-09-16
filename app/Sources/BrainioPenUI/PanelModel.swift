import AppKit
import Combine
import Foundation
import BrainioPenCore

/// Everything the panel draws, derived from a `PenLink` and a `SyncCoordinator` and nothing else.
/// Both of those already publish an `onChange` closure; this turns those into one observable
/// snapshot so the view never reaches into the pen or the git layer itself.
///
/// Lives on the main thread: every caller (`SyncCoordinator.finish`, the pen's marshalled SDK
/// callbacks) is already there.
public final class PanelModel: ObservableObject {
    /// What the header says, in the order the person cares about: a failure outranks a transfer,
    /// which outranks ordinary connected life.
    public enum Status: Equatable {
        case asleep                      // the A1 powers itself off after five minutes: the usual state
        case bluetoothOff
        case connecting
        case copying(book: Int, of: Int, percent: Int)
        case failing(attempts: Int, nextTry: Date?, error: String)
        case writing(page: PageLabel)
        case connected
    }

    public struct PendingRow: Identifiable, Equatable {
        public let id: String
        public let label: PageLabel
        /// Nil while the page is still being written: its timer restarts on every stroke, so a
        /// countdown there would tick backwards.
        public let deadline: Date?
        public let isLive: Bool

        public init(id: String, label: PageLabel, deadline: Date?, isLive: Bool) {
            self.id = id
            self.label = label
            self.deadline = deadline
            self.isLive = isLive
        }
    }

    public struct Publish: Equatable {
        public let date: Date
        public let commit: String?
        public let pages: Int

        public init(date: Date, commit: String?, pages: Int) {
            self.date = date
            self.commit = commit
            self.pages = pages
        }
    }

    @Published public private(set) var status: Status = .asleep
    @Published private(set) var penName = ""
    @Published public private(set) var battery: Battery?
    /// The flattest pen used in the last day, whether or not it is the one in your hand. With one
    /// pen this is the same fact; with three it is the one that matters, because the pen that
    /// needs charging is rarely the pen you are holding.
    @Published public private(set) var lowPen: (name: String, percent: Int)?

    /// The pens this Mac knows, newest reading first.
    @Published private(set) var pens: [PenRow] = []
    /// The pen whose settings you opened by clicking. Nothing else opens one: picking up a pen
    /// or starting a notebook used to open it too, and that kept a panel you had closed
    /// springing back open.
    @Published private(set) var chosenPen: String?
    /// The notebook the pen is writing in right now, by book key. Taken from the tracker rather
    /// than from the repo scan: the scan is what the panel was built from when it opened, and a
    /// notebook you switched to a minute ago is not in it yet.
    @Published private(set) var activeBook: String?

    /// The pen whose ink and width are showing: the one you clicked, and only that one. Closed
    /// by default, and a click on the open pen closes it again.
    var expandedPen: String? { chosenPen }

    func toggleExpanded(_ mac: String) {
        chosenPen = chosenPen == mac ? nil : mac
    }

    /// A pen that has left the list cannot stay open. Called from `refresh` once the rows are built.
    private func dropExpandedIfGone() {
        if let chosenPen, !pens.contains(where: { $0.id == chosenPen }) { self.chosenPen = nil }
    }

    /// The pen the open controls belong to.
    var expanded: PenRow? { pens.first { $0.id == expandedPen } }

    /// Changing ink for a pen that is not the one writing sets its default instead of the live
    /// selection — that pen is in a drawer, so there is no live anything to change.
    func choose(ink: InkColor, for pen: PenRow) {
        if pen.active { choose(ink: ink); return }
        guard let registry = live?.pens, var record = registry.record(mac: pen.id) else { return }
        record.ink = ink
        registry.save(record)
        refresh()
    }

    func choose(width: LineWidth, for pen: PenRow) {
        if pen.active { choose(width: width); return }
        guard let registry = live?.pens, var record = registry.record(mac: pen.id) else { return }
        record.width = width
        registry.save(record)
        refresh()
    }

    public struct PenRow: Identifiable, Equatable {
        public let id: String          // MAC
        public let name: String
        public let ink: InkColor
        public let width: LineWidth
        public let mode: PenMode
        public let percent: Int?
        public let low: Bool
        /// The pen you are using: the one connected, or failing that the one seen most recently.
        /// Reported by the hardware, never chosen by a click — you select a pen by picking it up,
        /// and a pen that is merely asleep is still the one you were last writing with.
        public let active: Bool
        /// This pen's own state, which is not the panel's. The header answers "is my writing
        /// safe"; this answers "is this pen awake", and after five idle minutes those two stop
        /// agreeing.
        public let state: String
        /// Connected right now, as opposed to merely being the last pen you used. The tile fills
        /// with ink only for this: the fill says "you are writing with this", and a pen that went
        /// to sleep twenty minutes ago is not something you are doing.
        public let awake: Bool
        /// How full the pen's own memory is, as a percentage — only while it is connected, for
        /// the same reason as the charge: a figure read hours ago looks live and is not.
        public let memory: Int?

        public init(id: String, name: String, ink: InkColor, width: LineWidth, mode: PenMode,
                    percent: Int?, low: Bool, active: Bool, state: String, awake: Bool,
                    memory: Int? = nil) {
            self.id = id
            self.name = name
            self.ink = ink
            self.width = width
            self.mode = mode
            self.percent = percent
            self.low = low
            self.active = active
            self.state = state
            self.awake = awake
            self.memory = memory
        }
    }
    @Published public private(set) var pending: [PendingRow] = []
    @Published private(set) var pagesOnPen: Int?
    @Published private(set) var lastPublish: Publish?
    @Published private(set) var isPublishing = false
    /// Pages whose transcript is older than the strokes on them. Nought when no agent is configured,
    /// which is how the panel knows to say nothing about transcription at all.
    @Published private(set) var owed = 0
    @Published private(set) var isTranscribing = false
    @Published private(set) var recent: [RecentBook] = []
    /// What is still to be done, newest page first, with the last thing done after it if there is
    /// room. Five at most: the panel is a glance, not a task list, and a sixth row would push the
    /// footer off a short screen.
    @Published public private(set) var actions: [ActionItem] = []

    /// Where the actions come from. Set by the app delegate; absent in the design window, which
    /// sets `actions` straight from a snapshot.
    public var actionsStore: ActionsStore?
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

    /// A notebook, not a page. What you reach for is the book; which page it falls open at is the
    /// viewer's job, and it always falls open at the last one you wrote.
    public struct RecentBook: Identifiable, Equatable {
        public let id: String
        public let title: String
        /// Where it will open: the most recently written page in it.
        public let page: PageRef
        /// The most recently written of all the notebooks. Marked, because "the one you are in"
        /// is what you are looking for when you open the panel.
        public var latest: Bool = false
        /// Loose sheets or a bound notebook — the two look different on the desk, so they look
        /// different here.
        public let binding: KnownBooks.Binding

        public init(id: String, title: String, page: PageRef, latest: Bool = false,
                    binding: KnownBooks.Binding) {
            self.id = id
            self.title = title
            self.page = page
            self.latest = latest
            self.binding = binding
        }
    }

    /// One line the writer addressed to an assistant, as the panel shows it. Taken whole from the
    /// actions store, which is the one place the files are read.
    public typealias ActionItem = ActionsStore.Item

    public struct Battery: Equatable {
        public let percent: Int
        public let charging: Bool
        public let low: Bool

        public init(percent: Int, charging: Bool, low: Bool) {
            self.percent = percent
            self.charging = charging
            self.low = low
        }
    }

    /// How many action rows the panel will draw, done and not done together.
    private static let actionsShown = 5

    /// A page written within this many seconds counts as being written right now.
    private static let liveWindow: TimeInterval = 45

    /// Everything the model derives from. Absent in the design window, which sets the published
    /// properties directly instead — that is the whole of what "design mode" means here.
    struct Live {
        let session: PenLink
        let coordinator: SyncCoordinator
        let config: Config
        let books: BookRegistry
        let pens: PenRegistry
        let penState: PenState
    }

    /// Set by the app delegate, and set again whenever the settings change. Nil while no agent is
    /// configured.
    public weak var processor: PageProcessor?

    private let live: Live?
    private var lastPaletteLoad = Date.distantPast

    public init(session: PenLink, coordinator: SyncCoordinator, config: Config,
                books: BookRegistry, pens: PenRegistry, penState: PenState) {
        live = Live(session: session, coordinator: coordinator, config: config,
                    books: books, pens: pens, penState: penState)
    }

    /// A model with no pen and no repo behind it, for the design window. What it shows comes
    /// from a `Snapshot` and from nothing else.
    public init(snapshot: Snapshot) {
        live = nil
        apply(snapshot)
    }

    /// Recompute from live state. Called on every change and once a second while the panel is open,
    /// which is what keeps the countdowns moving.
    public func refresh(now: Date = Date()) {
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
            palette = Palette.load(root: config.dataURL)
        }
        if let mode = coordinator.modeLog?.current {
            ink = mode.ink
            width = mode.width
        }
        isPublishing = coordinator.isPublishing
        // Asked of the files, like everything else about what is owed (ADR-004). Cheap: it is a
        // directory listing and one date comparison per page.
        owed = processor?.outstanding.count ?? 0
        isTranscribing = processor?.isTranscribing ?? false

        // Only while the pen is actually here. A percentage read hours ago looks live and is not,
        // and the macOS Bluetooth menu sets the convention: a battery for what is connected,
        // nothing at all for the rest.
        if let s = session.reading, session.isConnected {
            let pct = s.battery
            battery = Battery(percent: pct, charging: s.charging,
                              low: pct <= config.lowBatteryPercent && !s.charging)
            let held = PenMemory.pages(usedPercent: s.memoryUsedPercent)
            pagesOnPen = held > 0 ? held : nil
            if let mac = config.penMac {
                live.penState.record(mac: mac, battery: pct, charging: s.charging, at: now)
            }
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

        // The notebook with the newest stroke in it, which is the one the mark belongs on. When
        // it changes, the repo scan behind the list is out of date — a notebook you have just
        // started is not in it at all — so the list is rebuilt.
        if let newest = coordinator.tracker.pending.max(by: { $0.last < $1.last })?.page.folder.name,
           newest != activeBook {
            activeBook = newest
            refreshRecent()
        }
        markActiveBook()

        if let record = coordinator.lastPublish {
            lastPublish = Publish(date: record.date, commit: record.commit, pages: record.pages)
        }

        let readings = live.penState.all
        // Connected wins; otherwise the most recent reading. A pen sleeps after five minutes, so
        // insisting on a live connection would leave no pen marked for most of the day.
        let connected = session.isConnected
            ? PenRecord.normalise(config.penMac ?? "")
            : readings.max(by: { $0.value.at < $1.value.at })?.key
        let writingNow = coordinator.tracker.pending
            .contains { now.timeIntervalSince($0.last) < Self.liveWindow }
        pens = live.pens.pens.map { pen in
            let reading = readings[pen.mac]
            let here = session.isConnected && pen.mac == connected
            let state: String
            if !here {
                // The header used to carry this, above everything, in bold. It belongs to the
                // pen: the reason you cannot see your writing is a fact about this pen, and
                // Bluetooth being off is a different reason from the pen being asleep.
                switch session.linkState {
                case .bluetoothOff: state = "Bluetooth off"
                case .connecting, .authorizing: state = "Connecting"
                default: state = "Pen off"
                }
            } else if reading?.charging == true {
                state = "Charging"
            } else if writingNow {
                state = "Writing"
            } else {
                state = "Ready"
            }
            return PenRow(id: pen.mac, name: pen.name, ink: pen.ink, width: pen.width, mode: pen.mode,
                          percent: reading?.battery,
                          low: (reading.map { !$0.charging && $0.battery <= config.lowBatteryPercent }) ?? false,
                          active: pen.mac == connected, state: state, awake: here,
                          memory: here ? session.reading?.memoryUsedPercent : nil)
        }.sorted {
            // The one in your hand first, then by how recently each was seen.
            if $0.active != $1.active { return $0.active }
            return (readings[$0.id]?.at ?? .distantPast) > (readings[$1.id]?.at ?? .distantPast)
        }
        dropExpandedIfGone()

        // Any pen used in the last day, not just the connected one.
        if let worst = live.penState.lowBatteries(threshold: config.lowBatteryPercent, now: now).first {
            lowPen = (name: live.pens.name(mac: worst.mac), percent: worst.reading.battery)
        } else {
            lowPen = nil
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
        switch session.linkState {
        case .bluetoothOff:
            return .bluetoothOff
        case .scanning:
            return .asleep
        case .connecting, .authorizing:
            return .connecting
        case .draining:
            if let d = session.drainProgress {
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

    /// Scanning the repo is too much for the one-second tick, so the recent list is rebuilt only
    /// when the panel is opened.
    public func refreshRecent() {
        guard let books = live?.books else { return }
        // Newest first, one row per copy of a notebook: the same book appearing four times
        // because you wrote four pages in it says nothing you did not already know. A second copy
        // of one product is a second row, which is how a person learns the app decided there was
        // one (ADR-002).
        // The control strip is a book to the pen and a keyboard to a person. It is written on all
        // day and never read, so it is not a notebook to list.
        let utility = Set(live?.config.controlBooks ?? [])
        var seen = Set<String>()
        recent = books.recentPages(limit: 60).compactMap { entry in
            guard !utility.contains(entry.page.folder.surface) else { return nil }
            guard seen.insert(entry.page.folder.name).inserted else { return nil }
            let label = books.label(for: entry.page)
            return RecentBook(id: entry.page.folder.name,
                              title: label.title,
                              page: entry.page,
                              binding: books.record(for: entry.page)?.binding ?? .pad)
        }
        recent = Array(recent.prefix(4))
        markActiveBook()
        refreshActions()
    }

    /// The first few actions, from the store. Rebuilt with the notebook list and for the same
    /// reason: it is a directory walk, which is too much for the one-second tick.
    ///
    /// Everything outstanding comes first, and the last thing carried out follows it only if there
    /// is space left — the point of the list is what is still owed. What was called off is not
    /// here at all: a glance is for what is owed and what has just been settled, and something you
    /// decided against is neither.
    private func refreshActions() {
        guard let actionsStore else { return }
        actionsStore.reload()
        var outstanding: [ActionItem] = []
        var lastDone: ActionItem?
        for item in actionsStore.items {
            switch item.status {
            case .dismissed: continue
            case .done: if lastDone == nil { lastDone = item }
            case .new, .wip: outstanding.append(item)
            }
        }
        var rows = Array(outstanding.prefix(Self.actionsShown))
        if rows.count < Self.actionsShown, let lastDone { rows.append(lastDone) }
        actions = rows
    }

    /// One mark, on the notebook being written in. Falls back to the newest in the list, which is
    /// the same notebook whenever the app has been running long enough to have seen a stroke.
    private func markActiveBook() {
        let key = activeBook ?? recent.first?.id
        for i in recent.indices { recent[i].latest = recent[i].id == key }
    }

    /// Set by the app delegate, which owns the window.
    public var onOpenPage: ((PageRef) -> Void)?

    /// Never a PNG in Preview: one viewer, whether the ink arrived a second ago or last month.
    func open(_ book: RecentBook) { onOpenPage?(book.page) }

    /// Clicking the row opens the actions window on it — the conversation, the answer, the box to
    /// say the next thing. The page it was written on is one item down the row's own menu: the
    /// handwriting is the question, and by the time you are clicking a row you are usually after
    /// the answer.
    func open(_ action: ActionItem) { onOpenAction?(action.id) }

    /// The same four answers the window offers, from the menubar: done, do it, call it off, undo.
    /// The panel is where you see what is outstanding, so it is where you are when you decide.
    func setDone(_ item: ActionItem, _ done: Bool) {
        actionsStore?.setDone(item, done)
        refreshActions()
    }

    func setDismissed(_ item: ActionItem, _ dismissed: Bool) {
        actionsStore?.setDismissed(item, dismissed)
        refreshActions()
    }

    func run(_ item: ActionItem) {
        actionsStore?.run(item)
        refreshActions()
    }

    var busyActions: Set<String> { actionsStore?.busy ?? [] }

    /// Lines the agent has been stopped on, waiting for a person to allow something. The panel
    /// only says that one is; the answer is given in the actions window, which is a click away and
    /// has the room for what is being asked.
    func isWaiting(_ item: ActionItem) -> Bool {
        processor?.waiting(on: item.action.key).isEmpty == false
    }

    /// True when there is an agent to hand an action to. With none configured the menu offers only
    /// what a person can do alone.
    var canRun: Bool { actionsStore?.canRun ?? false }

    /// Set by the app delegate, which owns the actions window.
    public var onOpenAction: ((String) -> Void)?

    /// The window, with nothing opened in it.
    func showAllActions() { onOpenAction?("") }

        /// Set by the app delegate, which owns the window.
    public var onShowLive: (() -> Void)?

    func showLive() { onShowLive?() }

    /// True while the panel is also open in its own window.
    @Published private(set) var isPinned = false

    public var onTogglePin: (() -> Void)?

    func togglePin() { onTogglePin?() }

    /// Called by the app delegate when the pinned window opens or closes.
    public func setPinned(_ pinned: Bool) { isPinned = pinned }

    // MARK: actions

    public func publishNow() {
        live?.coordinator.publishAll()
    }

    /// Transcribe every page that is owed a transcript, oldest first, without waiting for any of them to go
    /// still. They go one at a time — an agent runs one turn at a time — so the count in the menu
    /// falls as they are done.
    func transcribeNow() {
        processor?.transcribeNow()
        refresh()
    }

    func openNotes() {
        guard let repo = live?.config.dataURL else { return }
        NSWorkspace.shared.open(repo)
    }

    /// Set by the app delegate, which owns the window.
    public var onOpenSettings: (() -> Void)?

    func openConfig() { onOpenSettings?() }

    /// Where the LaunchAgent sends stderr. Falls back to revealing the notes folder when the app
    /// was started by hand and the log is only on the terminal.
    func openLog() {
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BrainioPen/brainio-pen.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        } else if let repo = live?.config.dataURL {
            NSWorkspace.shared.open(repo)
        }
    }

    /// Choose an ink or a width from the panel. Written to the same log a paper tap writes to —
    /// one file, one writer, and the renderer cannot tell which of the two a change came from.
    func choose(ink: InkColor) {
        guard let log = live?.coordinator.modeLog else { return }
        log.record(.ink(ink), at: Int(Date().timeIntervalSince1970 * 1000), client: .app)
        refresh()
    }

    func choose(width: LineWidth) {
        guard let log = live?.coordinator.modeLog else { return }
        log.record(.width(width), at: Int(Date().timeIntervalSince1970 * 1000), client: .app)
        refresh()
    }

    /// True when the swatch has no measured colour behind it. The panel draws a hole; nothing
    /// substitutes black here, because a hole is honest and a wrong colour is not.
    /// The inks with a colour behind them, in the strip's own order. The paper has ten buttons;
    /// which of them mean anything is decided by palette.json, not here.
    var inks: [InkColor] { palette.offered }

    func pairDifferentPen() {
        live?.session.forgetPen()
    }

    // MARK: - a model with nothing behind it

    /// Every published property, as one value.
    ///
    /// This is the whole of the seam the design window needs: it hands over a state, the model
    /// shows it, and no fixture data lives in here. `private(set)` on the published properties is
    /// module-scoped, so without this the states would have to be written in this file — which is
    /// how a production model ends up carrying a hundred lines of make-believe.
    public struct Snapshot {
        public var status: Status = .asleep
        public var penName = "Pen"
        public var penDisplayName = "Pen"
        public var battery: Battery?
        public var lowPen: (name: String, percent: Int)?
        public var pens: [PenRow] = []
        public var pending: [PendingRow] = []
        public var pagesOnPen: Int?
        public var lastPublish: Publish?
        public var isPublishing = false
        public var recent: [RecentBook] = []
        public var actions: [ActionItem] = []
        public var lastSeen: Date?
        public var ink: InkColor = .black
        public var width: LineWidth = .default
        public var palette = Palette()
        /// The pen whose settings are open, by MAC, as if you had clicked its tile. Nil is the
        /// resting state: nothing opens on its own.
        public var openPen: String?

        public init() {}
    }

    /// Show exactly this and derive nothing. Only ever called on a model built with
    /// `init(snapshot:)`, which has no pen and no repo to derive from.
    public func apply(_ snapshot: Snapshot) {
        status = snapshot.status
        penName = snapshot.penName
        penDisplayName = snapshot.penDisplayName
        battery = snapshot.battery
        lowPen = snapshot.lowPen
        pens = snapshot.pens
        pending = snapshot.pending
        pagesOnPen = snapshot.pagesOnPen
        lastPublish = snapshot.lastPublish
        isPublishing = snapshot.isPublishing
        recent = snapshot.recent
        actions = snapshot.actions
        lastSeen = snapshot.lastSeen
        ink = snapshot.ink
        width = snapshot.width
        palette = snapshot.palette
        chosenPen = snapshot.openPen
        markActiveBook()
    }
}
