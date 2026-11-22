import XCTest
@testable import OpenSmartPenUI

/// The text of a transcript comes from the bucket. A link in it opens only the web.
final class TranscriptLinkTests: XCTestCase {
    private func links(_ markdown: String) throws -> [URL] {
        var text = try AttributedString(markdown: markdown, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))
        text.keepOnlyWebLinks()
        return text.runs.compactMap(\.link)
    }

    func testALinkToTheWebStays() throws {
        XCTAssertEqual(try links("see [the page](https://example.org/a) and <http://example.org/b>").map(\.absoluteString),
                       ["https://example.org/a", "http://example.org/b"])
    }

    func testALinkToAnythingElseIsOnlyWords() throws {
        let line = "[next](smb://host/share) [app](file:///Applications/Notes.app) [x](claude://cowork/new?q=hi) [y](HTTPS://example.org)"
        XCTAssertEqual(try links(line).map(\.absoluteString), ["HTTPS://example.org"])
        var text = try AttributedString(markdown: line)
        text.keepOnlyWebLinks()
        XCTAssertEqual(String(text.characters), "next app x y", "the words are kept")
    }
}
