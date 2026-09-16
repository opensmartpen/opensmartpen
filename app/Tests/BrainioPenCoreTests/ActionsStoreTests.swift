import Foundation
@testable import BrainioPenCore
@testable import BrainioPenUI
import XCTest

/// The three states a person recognises — nobody has touched it, somebody is on it, it is
/// finished — plus the one they called off. The rule worth testing is what makes a line "in hand":
/// somebody has said something about it, and it is not finished yet.
final class ActionsStoreTests: XCTestCase {
    private var root: URL!
    private var books: BookRegistry!
    private var ref: PageRef!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("brainio-pen-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RawStore(root: root, app: "c", sdk: "s")
        books = BookRegistry(root: root)
        let page = PageID(surface: "s3/o27/b450", page: 4)!
        let stroke = Stroke(page: page, start: 1_700_000_000_000, end: 1_700_000_000_010,
                            dots: [DotSample(x: 10, y: 20, force: 0.5, dt: 0)],
                            source: .live, penMac: "M", firmware: "F")
        let group = PageRouter(books: books, store: store).route([stroke])[0]
        _ = try store.append(group.strokes, to: group.folder)
        ref = PageRef(folder: group.folder, page: page)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store(_ actions: [PageAction]) throws -> ActionsStore {
        let url = try XCTUnwrap(PageActions.url(root: root, books: books, for: ref))
        try PageActions.save(actions, to: url)
        let store = ActionsStore(books: books, root: root)
        store.reload()
        return store
    }

    func testALineNobodyHasTouchedIsNew() throws {
        let store = try store([PageAction(text: "CALL")])
        XCTAssertEqual(store.items.map(\.status), [.new])
        XCTAssertEqual(store.items.first?.pageNumber, 4)
    }

    func testALineWithSomethingSaidAboutItIsInHand() throws {
        // Not finished, but started: the agent has answered and nobody has ticked it.
        let store = try store([PageAction(text: "FIND OUT WHO IS ONDREJ SIROKY",
                                          thread: [ActionMessage(from: .agent, text: "He runs delivery.")])])
        XCTAssertEqual(store.items.map(\.status), [.wip])
    }

    func testFinishedAndCalledOffOutrankWhatWasSaid() throws {
        let said = [ActionMessage(from: .agent, text: "Sent.")]
        let store = try store([PageAction(text: "SEND IT", done: true, thread: said),
                               PageAction(text: "CALL", dismissed: true, thread: said)])
        XCTAssertEqual(store.items.map(\.status), [.done, .dismissed])
    }

    func testTickingOneWritesItThroughToTheFile() throws {
        let store = try store([PageAction(text: "CALL")])
        let item = try XCTUnwrap(store.items.first)
        store.setDone(item, true)
        XCTAssertEqual(store.items.map(\.status), [.done])

        let url = try XCTUnwrap(PageActions.url(root: root, books: books, for: ref))
        XCTAssertEqual(PageActions.load(url).map(\.done), [true])

        // And back again: what the agent decided is never the last word.
        store.setDone(try XCTUnwrap(store.items.first), false)
        XCTAssertEqual(PageActions.load(url).map(\.done), [false])
    }

    func testARowThatIsGoneDoesNotStayOpen() throws {
        let store = try store([PageAction(text: "CALL")])
        store.expanded = try XCTUnwrap(store.items.first).id
        let url = try XCTUnwrap(PageActions.url(root: root, books: books, for: ref))
        try PageActions.save([], to: url)
        store.reload()
        XCTAssertNil(store.expanded)
    }

    func testStartingOverForgetsTheConversationAndTheSession() throws {
        let said = [ActionMessage(from: .you, text: "The seat plan."),
                    ActionMessage(from: .agent, text: "Sent to the wrong address, sorry.")]
        let store = try store([PageAction(text: "SEND THE PRICING", done: true, note: "Sent.",
                                          thread: said, session: "s-1", agent: "mailer")])
        store.startOver(try XCTUnwrap(store.items.first))

        let url = try XCTUnwrap(PageActions.url(root: root, books: books, for: ref))
        let action = try XCTUnwrap(PageActions.load(url).first)
        XCTAssertEqual(action.thread, [])
        XCTAssertNil(action.session)
        XCTAssertNil(action.note)
        XCTAssertFalse(action.done)
        // The line itself and where it goes are kept: it is the same errand, sent again.
        XCTAssertEqual(action.text, "SEND THE PRICING")
        XCTAssertEqual(action.agent, "mailer")
        XCTAssertEqual(store.items.map(\.status), [.new])
    }

    func testClearingTheConversationForgetsItWithoutSending() throws {
        let said = [ActionMessage(from: .you, text: "The seat plan."),
                    ActionMessage(from: .agent, text: "Sent to the wrong address, sorry.")]
        let store = try store([PageAction(text: "SEND THE PRICING", done: true, note: "Sent.",
                                          thread: said, session: "s-1", agent: "mailer")])
        store.clearConversation(try XCTUnwrap(store.items.first))

        let url = try XCTUnwrap(PageActions.url(root: root, books: books, for: ref))
        let action = try XCTUnwrap(PageActions.load(url).first)
        XCTAssertEqual(action.thread, [])
        XCTAssertNil(action.session)
        XCTAssertNil(action.note)
        XCTAssertFalse(action.done)
        XCTAssertEqual(action.text, "SEND THE PRICING")
        XCTAssertEqual(action.agent, "mailer")
        XCTAssertEqual(store.items.map(\.status), [.new])
        // Nothing was sent: the row is clean and idle.
        XCTAssertTrue(store.busy.isEmpty)
    }

    func testWithNoAgentNothingCanBeHandedOver() throws {
        let store = try store([PageAction(text: "CALL")])
        XCTAssertFalse(store.canRun)
        store.run(try XCTUnwrap(store.items.first))
        XCTAssertTrue(store.busy.isEmpty)
    }
}
