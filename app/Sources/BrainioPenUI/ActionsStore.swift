import Combine
import Foundation
import BrainioPenCore

/// Every line the notebooks ask for, in one place.
///
/// The actions were read twice before this — once by the viewer for the sheets on screen, once by
/// the menubar panel for its short list — and each did its own walk of the files. They are one
/// list: what the pages ask for, newest first, whatever page happens to be open. A window shows all
/// of it, the panel shows the first few, and both are looking at this.
public final class ActionsStore: ObservableObject {
    /// What has become of one line. Three states a person recognises, and a fourth for what they
    /// called off.
    public enum Status: Equatable {
        /// Nobody has touched it.
        case new
        /// Somebody is on it: the agent has said something, or is saying it right now.
        case wip
        case done
        /// Deleted by you. Out of the list unless you ask to see them.
        case dismissed
    }

    /// Whether deleted lines are shown. Off by default — deleting something and having it stay on
    /// the list is not deleting it.
    @Published public var showDeleted = false

    public struct Item: Identifiable, Equatable {
        public let id: String
        public let page: PageRef
        /// The notebook it is written in, and which sheet of it.
        public let book: String
        public let pageNumber: Int
        /// When that page was last written on — what "latest" is measured by.
        public let written: Date
        public var action: PageAction
        public var status: Status

        public init(id: String, page: PageRef, book: String, pageNumber: Int, written: Date,
                    action: PageAction, status: Status) {
            self.id = id
            self.page = page
            self.book = book
            self.pageNumber = pageNumber
            self.written = written
            self.action = action
            self.status = status
        }

        public var text: String { action.text }
    }

    @Published public private(set) var items: [Item] = []
    /// Which row is open. One at a time: a conversation is long, and two of them open at once is a
    /// scroll bar instead of a list.
    @Published public var expanded: String?
    /// Rows with a turn running, by id.
    @Published public private(set) var busy: Set<String> = []
    /// What went wrong, by row. Shown on the row rather than in a dialog, because it is about that
    /// one line.
    @Published public private(set) var failures: [String: String] = [:]

    /// Who carries an action out. Nil when no agent is configured, and then the window offers only
    /// what a person can do alone.
    public weak var processor: PageProcessor? {
        didSet { objectWillChange.send() }
    }

    /// Set by the app delegate, which owns the viewer window.
    public var onOpenPage: ((PageRef) -> Void)?
    /// Set by the app delegate. The way out of "there are no agents yet".
    public var onOpenSettings: (() -> Void)?

    /// The agents an action can be handed to. Set by the app delegate from the config, so the row
    /// can name the one that was chosen and offer the rest.
    public var roster: [DamAgentProfile] = [] {
        didSet { objectWillChange.send() }
    }

    /// The agent an action is routed to, as a person reads it. Nil means nobody chose, and it goes
    /// to the reader — the agent with nothing to reach.
    public func agentName(_ item: Item) -> String? {
        guard let id = item.action.agent else { return nil }
        return roster.first { $0.id == id }?.name ?? id
    }

    /// Route it somewhere else. Always a person's to change: the reader proposes from a page, and
    /// a page is not something to take instructions from.
    public func setAgent(_ item: Item, to id: String?) {
        change(item) { $0.agent = id }
    }

    private let books: BookRegistry
    private let root: URL

    public init(books: BookRegistry, root: URL) {
        self.books = books
        self.root = root
    }

    public var canRun: Bool { processor != nil }

    /// Read every action off disk again.
    ///
    /// A directory walk and a handful of small files. Called when the window opens, after anything
    /// is changed, and on a slow tick while it is open — the agent writes these files too, and a
    /// window left open should not go stale.
    public func reload(limit: Int = 60) {
        var found: [Item] = []
        for entry in books.recentPages(limit: limit) {
            guard let url = PageActions.url(root: root, books: books, for: entry.page) else { continue }
            let label = books.label(for: entry.page)
            let number = books.record(for: entry.page)?.humanPage(entry.page.page.page) ?? entry.page.page.page
            for action in PageActions.load(url) {
                let id = "\(entry.page.folder.name)/\(number)/\(action.key)"
                found.append(Item(id: id, page: entry.page, book: label.title, pageNumber: number,
                                  written: entry.written, action: action,
                                  status: status(of: action, id: id)))
            }
        }
        items = found
        // A row that has gone — the page was rewritten and the line with it — should not stay open.
        if let expanded, !found.contains(where: { $0.id == expanded }) { self.expanded = nil }
    }

    private func status(of action: PageAction, id: String) -> Status {
        switch action.state {
        case .dismissed: return .dismissed
        case .done: return .done
        case .open: return (busy.contains(id) || !action.thread.isEmpty) ? .wip : .new
        }
    }

    // MARK: - The four answers

    /// Done, or not done after all. Always a person's to set, whatever the agent decided: the agent
    /// says what it did, and you say whether that finished it.
    public func setDone(_ item: Item, _ done: Bool) {
        change(item) { $0.done = done; if done { $0.dismissed = false } }
    }

    public func setDismissed(_ item: Item, _ dismissed: Bool) {
        change(item) { $0.dismissed = dismissed }
    }

    private func change(_ item: Item, _ edit: (inout PageAction) -> Void) {
        guard let url = PageActions.url(root: root, books: books, for: item.page) else { return }
        try? PageActions.update(url, key: item.action.key, edit)
        reload()
    }

    /// Hand one to the agent, with the page, everything said about it so far, and whatever you
    /// have just typed. The same door for the first ask, for the part the paper left out, and for
    /// the answer to a question it came back with.
    public func run(_ item: Item, say: String? = nil) {
        guard let processor, !busy.contains(item.id) else { return }
        busy.insert(item.id)
        failures[item.id] = nil
        reload()
        processor.execute(action: item.action, on: item.page, say: say) { [weak self] error in
            guard let self else { return }
            busy.remove(item.id)
            failures[item.id] = error?.localizedDescription
            reload()
        }
    }

    public func isBusy(_ item: Item) -> Bool { busy.contains(item.id) }
    public func failure(_ item: Item) -> String? { failures[item.id] }

    // MARK: - What the agent is waiting to be allowed to do

    /// Rows whose answer is being sent, by ask.
    @Published public private(set) var deciding: Set<String> = []

    /// A question put on a row by hand, by the `--show-approval` dev flag and nothing else.
    ///
    /// The card underneath this is the one piece of the window that cannot be reached by clicking:
    /// it appears only when a live agent is stopped at DAM's gate. Without a way to put one on
    /// screen it would be designed blind, which is how the last six faults got in.
    public var rehearsed: [String: [ApprovalAsk]] = [:] {
        didSet { objectWillChange.send() }
    }

    /// What is held up on this line. Only ever a line with a turn in the air: DAM asks while the
    /// work is running, and the question dies with the turn.
    public func waiting(_ item: Item) -> [ApprovalAsk] {
        if let rehearsed = rehearsed[item.id] { return rehearsed }
        return processor?.waiting(on: item.action.key) ?? []
    }

    /// Yes, yes-from-now-on, or no.
    ///
    /// The answer goes to DAM, not into any file of ours: the agent is stopped mid-job waiting for
    /// it, and what a person allowed once is the platform's business to remember, not ours.
    public func decide(_ item: Item, _ ask: ApprovalAsk, _ verdict: ApprovalVerdict) {
        guard let processor, !deciding.contains(ask.id) else { return }
        deciding.insert(ask.id)
        failures[item.id] = nil
        Task { @MainActor [weak self] in
            do {
                try await processor.decide(ask, on: item.action.key, verdict)
            } catch {
                self?.failures[item.id] = error.localizedDescription
            }
            self?.deciding.remove(ask.id)
            self?.reload()
        }
    }

    public func isDeciding(_ ask: ApprovalAsk) -> Bool { deciding.contains(ask.id) }
}
