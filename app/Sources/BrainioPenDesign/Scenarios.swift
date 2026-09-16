import BrainioPenCore
import BrainioPenUI
import Foundation

private typealias Snapshot = PanelModel.Snapshot
private typealias PenRow = PanelModel.PenRow
private typealias PendingRow = PanelModel.PendingRow
private typealias RecentBook = PanelModel.RecentBook
private typealias ActionItem = PanelModel.ActionItem
private typealias Battery = PanelModel.Battery
private typealias Publish = PanelModel.Publish

/// The states the panel can be in, as fixtures.
///
/// They are here, and not in the model, because none of this is true: it is make-believe for
/// looking at. Nothing in the shipped app can import this module, so none of it can reach the
/// menubar by accident.
///
/// They exist at all because several of these states are hard to reach on demand with real
/// hardware: a failing push, a pen memory drain and a first run each take deliberate setup to
/// see even once.
public enum Scenario: String, CaseIterable {
    case synced, writing, waiting, copying, failing, asleep, bluetoothOff, firstRun
    case newNotebook, threePens, penOpen

    public var title: String {
        switch self {
        case .synced: return "All synced"
        case .writing: return "Writing"
        case .waiting: return "Waiting to sync"
        case .copying: return "Copying"
        case .failing: return "Can\u{2019}t sync"
        case .asleep: return "No pen"
        case .bluetoothOff: return "Bluetooth off"
        case .firstRun: return "First run"
        case .newNotebook: return "A second pad"
        case .threePens: return "Three pens"
        case .penOpen: return "Pen settings"
        }
    }

    public var note: String {
        switch self {
        case .synced: return "nothing pending, pen awake"
        case .writing: return "strokes arriving now"
        case .waiting: return "in the quiet window"
        case .copying: return "draining pen memory"
        case .failing: return "3+ push failures"
        case .asleep: return "the usual state"
        case .bluetoothOff: return "the one real blocker"
        case .firstRun: return "never paired"
        case .newNotebook: return "two copies, decided silently"
        case .threePens: return "what the width is cut for"
        case .penOpen: return "a tile clicked open"
        }
    }

    /// Everything the panel draws, for this state. Built fresh on every read: the countdowns are
    /// measured from `now`, so a fixture held from an hour ago would show an hour of overdue.
    public var snapshot: PanelModel.Snapshot {
        let now = Date()
        let lamy = Self.label("LAMY digital paper", 6)
        let pad = Self.label("Ncode A4 pad", 3)
        var s = Self.base(now: now)

        switch self {
        case .synced:
            s.status = .connected
        case .writing:
            s.pending = [PendingRow(id: "p1", label: lamy, deadline: nil, isLive: true)]
            s.status = .writing(page: lamy)
        case .waiting:
            s.pending = [PendingRow(id: "p1", label: lamy, deadline: now.addingTimeInterval(372), isLive: false),
                         PendingRow(id: "p2", label: pad, deadline: now.addingTimeInterval(161), isLive: false)]
            s.status = .connected
        case .copying:
            s.pagesOnPen = 3
            s.status = .copying(book: 2, of: 5, percent: 62)
        case .failing:
            s.pending = [PendingRow(id: "p1", label: lamy, deadline: now, isLive: false),
                         PendingRow(id: "p2", label: pad, deadline: now, isLive: false)]
            s.recent = []
            s.status = .failing(attempts: 4, nextTry: now.addingTimeInterval(120),
                                error: "fatal: could not read from remote repository")
        case .asleep:
            s.status = .asleep
        case .bluetoothOff:
            s.battery = nil
            s.status = .bluetoothOff
        case .firstRun:
            s.battery = nil
            s.lastPublish = nil
            s.recent = []
            s.status = .asleep
        case .newNotebook:
            // A fresh pad is not announced, it simply appears: a second row with the same title
            // and a folder of its own. Nothing is asked, and no notice is posted (ADR-002).
            s.status = .connected
            s.recent.insert(Self.book("s3-o27-b450-0c41ab", "Ncode A4 pad",
                                      PageID(section: 3, owner: 27, book: 450, page: 1),
                                      latest: true, binding: .pad), at: 0)
            for i in s.recent.indices where i > 0 { s.recent[i].latest = false }
        case .threePens:
            // The width the panel is cut to. Three tiles and the pin are what decides it, so the
            // case has to be visible — a measurement nobody can look at goes wrong unnoticed.
            s.pens.append(PenRow(id: "c", name: "Highlighter", ink: .yellow, width: .thick,
                                 mode: .highlight, percent: 48, low: false, active: false,
                                 state: "Pen off", awake: false))
            s.status = .connected
        case .penOpen:
            // The ink and width controls under a tile. Only a click opens them — the panel no
            // longer opens the pen in your hand by itself — so the state has to be posed here,
            // or the one part of the panel you configure a pen from is never seen in the design
            // window at all.
            s.openPen = "a"
            s.status = .connected
        }
        return s
    }

    /// What every state has in common: two pens, a full palette and two notebooks written in
    /// recently. Each case then changes only what it is about.
    private static func base(now: Date) -> Snapshot {
        var s = Snapshot()
        s.penName = "Pen"
        s.penDisplayName = "Everyday"
        s.lowPen = ("Red one", 14)
        s.pens = [
            PenRow(id: "a", name: "Everyday", ink: .black, width: .medium, mode: .writing,
                   percent: 72, low: false, active: true, state: "Writing", awake: true, memory: 12),
            PenRow(id: "b", name: "Red one", ink: .red, width: .thin, mode: .accent,
                   percent: 14, low: true, active: false, state: "Pen off", awake: false),
        ]
        s.palette = Palette(ink: ["black": "#000000", "red": "#ff0200", "blue": "#00abeb",
                                  "green": "#3cdd00", "yellow": "#ffd400"])
        s.ink = .red
        s.width = .medium
        s.battery = Battery(percent: 16, charging: false, low: true)
        s.lastPublish = Publish(date: now.addingTimeInterval(-260), commit: "4e35b96", pages: 2)
        s.recent = [
            Self.book("s3-o1012-b3017-2b81e4", "LAMY digital paper",
                      PageID(section: 3, owner: 1012, book: 3017, page: 6),
                      latest: true, binding: .bound),
            Self.book("s3-o27-b450-7f3a9c", "Ncode A4 pad",
                      PageID(section: 3, owner: 27, book: 450, page: 3), binding: .pad),
        ]
        s.actions = [
            Self.action("1", "Find out who is Ondrej Siroky from Apoco", done: false),
            Self.action("2", "Send the pricing to Brainio", done: false),
            Self.action("3", "Call the landlord back", done: true),
        ]
        return s
    }

    /// The actions column with one of everything on it: a line nobody has touched, one the agent
    /// is on and has come back with a question, two finished, one thrown out. Static, because
    /// the column is not what changes between scenarios; the panel is.
    static var actionsColumn: [ActionsStore.Item] {
        let page = PageRef(folder: BookFolder(name: "s3-o1012-b3017-2b81e4")!,
                           page: PageID(section: 3, owner: 1012, book: 3017, page: 6))
        let now = Date()
        func item(_ id: String, _ action: PageAction, page number: Int = 6, ago: TimeInterval = 0,
                  status: ActionsStore.Status) -> ActionsStore.Item {
            ActionsStore.Item(id: id, page: page, book: "LAMY digital paper", pageNumber: number,
                       written: now.addingTimeInterval(-ago), action: action, status: status)
        }
        return [
            item("1", PageAction(text: "Find out who is Ondřej Široký from Apoco"), status: .new),
            item("2", PageAction(text: "Send the pricing to Brainio",
                                 note: "Which pricing — the seat plan or the API rates?",
                                 thread: [
                                     ActionMessage(from: .agent,
                                                   text: "I found two price lists in the drive. Which pricing — the **seat plan** or the **API rates**?"),
                                 ]), status: .wip),
            item("3", PageAction(text: "Book the dentist for the week after next"),
                 page: 5, ago: 86_400, status: .new),
            item("4", PageAction(text: "Call the landlord back", done: true), page: 4, ago: 2 * 86_400,
                 status: .done),
            item("5", PageAction(text: "Renew the domain", done: true), page: 4, ago: 2 * 86_400,
                 status: .done),
            item("6", PageAction(text: "Try the new coffee place", dismissed: true), page: 3,
                 ago: 3 * 86_400, status: .dismissed),
        ]
    }

    private static func action(_ id: String, _ text: String, done: Bool) -> ActionItem {
        ActionItem(id: id,
                   page: PageRef(folder: BookFolder(name: "s3-o1012-b3017-2b81e4")!,
                                 page: PageID(section: 3, owner: 1012, book: 3017, page: 6)),
                   book: "LAMY digital paper", pageNumber: 6, written: Date(),
                   action: PageAction(text: text, done: done), status: done ? .done : .new)
    }

    private static func book(_ folder: String, _ title: String, _ page: PageID,
                            latest: Bool = false, binding: KnownBooks.Binding) -> RecentBook {
        RecentBook(id: folder, title: title,
                   page: PageRef(folder: BookFolder(name: folder)!, page: page),
                   latest: latest, binding: binding)
    }

    private static func label(_ title: String, _ page: Int) -> PageLabel {
        PageLabel(title: title, detail: "page \(page)")
    }
}
