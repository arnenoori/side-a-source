import XCTest
@testable import SideARemote

final class StreamingMarkdownTests: XCTestCase {
    func testFinishedParagraphsFreezeAndTheLastOneStaysLive() {
        let text = "First paragraph.\n\nSecond one is still"
        XCTAssertEqual(StreamingMarkdown.frozenEnd(of: text), "First paragraph.\n\n".count)
        XCTAssertEqual(StreamingMarkdown.frozenEnd(of: "Only one so far"), 0)
        // A trailing blank line doesn't freeze anything until the next block starts.
        XCTAssertEqual(StreamingMarkdown.frozenEnd(of: "Done.\n\n"), 0)
    }

    func testABlankLineInsideAnOpenCodeFenceIsNotABoundary() {
        let text = "Intro.\n\n```swift\nlet a = 1\n\nlet b = 2"
        XCTAssertEqual(StreamingMarkdown.frozenEnd(of: text), "Intro.\n\n".count)
        let closed = text + "\n```\n\nAfter."
        XCTAssertEqual(StreamingMarkdown.frozenEnd(of: closed), closed.count - "After.".count)
    }

    func testRevealsStopAtWordEnds() {
        XCTAssertEqual(StreamingMarkdown.wordBoundary(in: "hello world", atOrAfter: 2), 5)
        XCTAssertEqual(StreamingMarkdown.wordBoundary(in: "hello world", atOrAfter: 99), 11)
    }
}
