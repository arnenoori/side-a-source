import XCTest
@testable import SideASessionKit

final class StreamingTextTests: XCTestCase {
    func testFinishedParagraphsFreezeAndTheLastOneStaysLive() {
        let text = "First paragraph.\n\nSecond one is still"
        XCTAssertEqual(StreamingText.frozenEnd(of: text), "First paragraph.\n\n".count)
        XCTAssertEqual(StreamingText.frozenEnd(of: "Only one so far"), 0)
        XCTAssertEqual(StreamingText.frozenEnd(of: "Done.\n\n"), 0)
    }

    func testABlankLineInsideAnOpenCodeFenceIsNotABoundary() {
        let text = "Intro.\n\n```swift\nlet a = 1\n\nlet b = 2"
        XCTAssertEqual(StreamingText.frozenEnd(of: text), "Intro.\n\n".count)
        let closed = text + "\n```\n\nAfter."
        XCTAssertEqual(StreamingText.frozenEnd(of: closed), closed.count - "After.".count)
    }

    func testRevealsStopAtWordEnds() {
        XCTAssertEqual(StreamingText.wordBoundary(in: "hello world", atOrAfter: 2), 5)
        XCTAssertEqual(StreamingText.wordBoundary(in: "hello world", atOrAfter: 99), 11)
    }
}
