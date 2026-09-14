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
    /// A pen you opened by clicking, which overrides the one in your hand until you close it.
    @Published private(set) var chosenPen: String?
    /// Set by clicking the open pen shut. Cleared the moment a different pen starts writing,
    /// because that is a new question, not the one you dismissed.
    @Published private(set) var penClosed = false
    /// The notebook the pen is writing in right now, by book key. Taken from the tracker rather
    /// than from the repo scan: the scan is what the panel was built from when it opened, and a
    /// notebook you switched to a minute ago is not in it yet.
    @Published private(set) var activeBook: String?
    /// The pen that was writing last time we looked, to notice when it changes.
    private var lastActivePen: String?

    /// The pen whose ink and width are showing.
    ///
    /// Open by default, and open on the pen you are holding: picking up a pen is the clearest
    /// statement of which pen you mean, and making you click for it afterwards asks you to say
    /// it twice. A click still overrides, and a click on the open pen closes it.
    var expandedPen: String? {
        if let chosenPen { return chosenPen }
        if penClosed { return nil }
        return pens.first { $0.active }?.id
    }

    func toggleExpanded(_ mac: String) {
        if expandedPen == mac {
            chosenPen = nil
            penClosed = true
        } else {
            chosenPen = mac
            penClosed = false
        }
    }

    /// A pen picking up the writing re-opens the panel on it, whatever was open before. Called
    /// from `refresh` once the rows are built.
    private func followActivePen() {
        let active = pens.first { $0.active }?.id
        guard active != lastActivePen else { return }
        lastActivePen = active
        openTheActivePen()
    }

    /// Also on a new notebook: starting to write somewhere else is the same kind of event as
    /// picking up a different pen, and the answer to both is "show me what I am writing with".
    private func openTheActivePen() {
        chosenPen = nil
        penClosed = false
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

        public init(id: String, name: String, ink: InkColor, width: LineWidth, mode: PenMode,
                    percent: Int?, low: Bool, active: Bool, state: String, awake: Bool) {
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
        }
    }
    @Published public private(set) var pending: [PendingRow] = []
    @Published private(set) var pagesOnPen: Int?
    @Published private(set) var lastPublish: Publish?
    @Published private(set) var isPublishing = false
    @Published private(set) var recent: [RecentBook] = []
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
        // started is not in it at all — so the list is rebuilt and the pen re-opened.
        if let newest = coordinator.tracker.pending.max(by: { $0.last < $1.last })?.page.folder.name,
           newest != activeBook {
            activeBook = newest
            refreshRecent()
            openTheActivePen()
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
                          active: pen.mac == connected, state: state, awake: here)
        }.sorted {
            // The one in your hand first, then by how recently each was seen.
            if $0.active != $1.active { return $0.active }
            return (readings[$0.id]?.at ?? .distantPast) > (readings[$1.id]?.at ?? .distantPast)
        }
        followActivePen()

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
        var seen = Set<String>()
        recent = books.recentPages(limit: 60).compactMap { entry in
            guard seen.insert(entry.page.folder.name).inserted else { return nil }
            let label = books.label(for: entry.page)
            return RecentBook(id: entry.page.folder.name,
                              title: label.title,
                              page: entry.page,
                              binding: books.record(for: entry.page)?.binding ?? .pad)
        }
        recent = Array(recent.prefix(4))
        markActiveBook()
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
        public var lastSeen: Date?
        public var ink: InkColor = .black
        public var width: LineWidth = .default
        public var palette = Palette()

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
        lastSeen = snapshot.lastSeen
        ink = snapshot.ink
        width = snapshot.width
        palette = snapshot.palette
        markActiveBook()
    }
}
