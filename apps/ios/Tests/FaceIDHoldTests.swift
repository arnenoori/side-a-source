import XCTest
@testable import SideARemote

final class FaceIDHoldTests: XCTestCase {
    private final class Token: @unchecked Sendable {
        nonisolated(unsafe) var invalidated = false
    }

    private final class Prompts: @unchecked Sendable {
        private let lock = NSLock()
        private var made = 0
        private var gate: CheckedContinuation<Void, Never>?
        private var open = true
        private var inFlight = false

        var count: Int { lock.withLock { made } }
        var waiting: Bool { lock.withLock { inFlight } }

        func hold() { lock.withLock { open = false } }

        func release() {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                open = true
                defer { gate = nil }
                return gate
            }
            waiter?.resume()
        }

        func prompt(accept: Bool = true) async -> FaceIDHold<Token>.Evaluated? {
            lock.withLock { made += 1; inFlight = true }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if open { return true }
                    gate = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
            lock.withLock { inFlight = false }
            return accept ? .init(context: Token()) : nil
        }
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ line: String) { lock.withLock { all.append(line) } }
        var text: String { lock.withLock { all.joined(separator: "\n") } }
    }

    private let lines = Lines()

    private func settled(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "never settled")
    }

    private func hold() -> FaceIDHold<Token> {
        let lines = lines
        return FaceIDHold(invalidate: { $0.invalidated = true }, log: { lines.add($0) })
    }

    func testOnePromptHoldsForEverySignatureAfterIt() async throws {
        let hold = hold()
        let prompts = Prompts()
        let firstAsked = await hold.context(reason: "a", evaluate: { _ in await prompts.prompt() })
        let first = try XCTUnwrap(firstAsked)
        XCTAssertFalse(first.reused)
        for _ in 0..<5 {
            let nextAsked = await hold.context(reason: "b", evaluate: { _ in await prompts.prompt() })
        let next = try XCTUnwrap(nextAsked)
            XCTAssertTrue(next.reused)
            XCTAssertTrue(next.context === first.context)
        }
        XCTAssertEqual(prompts.count, 1)
    }

    func testADeclinedPromptHoldsNothingAndAsksAgain() async throws {
        let hold = hold()
        let prompts = Prompts()
        let declined = await hold.context(reason: "a", evaluate: { _ in await prompts.prompt(accept: false) })
        XCTAssertNil(declined)
        XCTAssertFalse(hold.held)
        let accepted = await hold.context(reason: "a", evaluate: { _ in await prompts.prompt() })
        XCTAssertNotNil(accepted)
        XCTAssertEqual(prompts.count, 2)
    }

    func testTwoSignaturesWhileThePromptIsUpShareIt() async throws {
        let hold = hold()
        let prompts = Prompts()
        prompts.hold()
        async let one = hold.context(reason: "a", evaluate: { _ in await prompts.prompt() })
        try await settled { prompts.waiting }
        async let two = hold.context(reason: "b", evaluate: { _ in await prompts.prompt() })
        prompts.release()
        let (first, second) = await (one, two)
        let one1 = try XCTUnwrap(first)
        let two1 = try XCTUnwrap(second)
        XCTAssertTrue(one1.context === two1.context)
        XCTAssertEqual(prompts.count, 1)
    }

    func testExpiringEndsTheHoldInvalidatesItAndNamesWhy() async throws {
        let hold = hold()
        let prompts = Prompts()
        let firstAsked = await hold.context(reason: "a", evaluate: { _ in await prompts.prompt() })
        let first = try XCTUnwrap(firstAsked)
        hold.expire("the app was away")
        XCTAssertTrue(first.context.invalidated)
        XCTAssertFalse(hold.held)
        let secondAsked = await hold.context(reason: "a", evaluate: { _ in await prompts.prompt() })
        let second = try XCTUnwrap(secondAsked)
        XCTAssertFalse(second.reused)
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(lines.text.contains("Face ID asked: expired: the app was away"), lines.text)
    }

    func testAPromptThatFinishesAfterTheAppLeftIsNotKept() async throws {
        let hold = hold()
        let prompts = Prompts()
        prompts.hold()
        async let pending = hold.context(reason: "a", evaluate: { _ in await prompts.prompt() })
        try await settled { prompts.waiting }
        hold.expire("the app was away")
        prompts.release()
        let grant = await pending
        XCTAssertNotNil(grant)
        XCTAssertFalse(hold.held)
        _ = await hold.context(reason: "a", evaluate: { _ in await prompts.prompt() })
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(lines.text.contains("Face ID asked: expired while the prompt was up"), lines.text)
    }

    func testARefusedSignatureDropsTheHeldContextAndLogsItsCode() async throws {
        let hold = hold()
        let prompts = Prompts()
        let firstAsked = await hold.context(reason: "a", evaluate: { _ in await prompts.prompt() })
        let first = try XCTUnwrap(firstAsked)
        hold.drop(first.context, code: -3)
        XCTAssertFalse(hold.held)
        let secondAsked = await hold.context(reason: "a", evaluate: { _ in await prompts.prompt() })
        let second = try XCTUnwrap(secondAsked)
        XCTAssertFalse(second.reused)
        XCTAssertTrue(lines.text.contains("refused by the key (code -3)"), lines.text)
    }

    func testDroppingAContextThatIsNoLongerHeldChangesNothing() async throws {
        let hold = hold()
        let prompts = Prompts()
        let firstAsked = await hold.context(reason: "a", evaluate: { _ in await prompts.prompt() })
        let first = try XCTUnwrap(firstAsked)
        hold.expire("locked")
        let secondAsked = await hold.context(reason: "a", evaluate: { _ in await prompts.prompt() })
        let second = try XCTUnwrap(secondAsked)
        hold.drop(first.context, code: -1)
        XCTAssertTrue(hold.held)
        XCTAssertTrue(second.context !== first.context)
    }

    func testAdoptedContextIsReusedWithoutAPrompt() async throws {
        let hold = hold()
        let prompts = Prompts()
        let adopted = Token()
        hold.adopt(adopted)
        let grantAsked = await hold.context(reason: "a", evaluate: { _ in await prompts.prompt() })
        let grant = try XCTUnwrap(grantAsked)
        XCTAssertTrue(grant.reused)
        XCTAssertTrue(grant.context === adopted)
        XCTAssertEqual(prompts.count, 0)
    }

    func testTheFirstPromptSaysItIsTheFirst() async throws {
        let hold = hold()
        let prompts = Prompts()
        _ = await hold.context(reason: "a", evaluate: { _ in await prompts.prompt() })
        XCTAssertTrue(lines.text.contains("Face ID asked: no Face ID yet in this launch"), lines.text)
    }
}
