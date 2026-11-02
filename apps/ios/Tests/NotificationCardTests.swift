import SideAProtocol
import UserNotifications
import XCTest
@testable import SideARemote

@MainActor
final class NotificationCardTests: XCTestCase {
    private func card(_ questions: [IslandQuestion]?, full: Bool = true, mac: String = NotificationAnswer.demoMac) throws -> NotificationCardModel {
        let payload = PushPayload(t: "question", mac: mac, sent: 1_000, rid: "r1", sid: "s1", title: "Question for you",
                                  subtitle: "side-a · Work", questions: questions, full: full)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
        let decoded = try XCTUnwrap(PushPayload(userInfo: ["p": object]))
        XCTAssertEqual(decoded, payload)
        return NotificationCardModel(category: "QUESTION", payload: decoded)
    }

    private let cache = IslandQuestion(question: "Where should the cache live?", header: "Cache",
                                       options: [.init(label: "App Group (Recommended)", description: nil), .init(label: "Caches", description: nil)],
                                       multiSelect: false)
    private let platforms = IslandQuestion(question: "Which platforms?", header: nil,
                                           options: [.init(label: "iOS", description: nil), .init(label: "macOS", description: nil)],
                                           multiSelect: true)

    func testASetPagesThenSendsEveryAnswer() async throws {
        let card = try card([cache, platforms])
        card.tap(cache.options[0])
        XCTAssertEqual(card.page, 1)
        XCTAssertEqual(card.sending, .idle)
        card.tap(platforms.options[1])
        card.tap(platforms.options[0])
        card.tap(platforms.options[1])
        XCTAssertEqual(card.picked[1], ["iOS"])
        card.advance()
        XCTAssertEqual(card.sending, .sending)
        for _ in 0..<40 where card.sending == .sending { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(card.sending, .sent)
    }

    func testTypedAnswerReplacesThePickOnASingleChoice() throws {
        let card = try card([cache, platforms])
        card.typed("  Keychain  ")
        XCTAssertEqual(card.page, 1)
        XCTAssertEqual(card.picked[0], [])
    }

    /// A set that didn't fit shows Open only, never part of it.
    func testPartialSetOffersNoOptions() throws {
        XCTAssertNil(try card([cache], full: false).question)
    }

    func testActionsMapToAnswers() {
        XCTAssertEqual(NotificationCategories.answer(for: "ALLOW"), .allow(confirmDestructive: false))
        XCTAssertEqual(NotificationCategories.answer(for: "APPROVE_EDITS"), .approvePlan(acceptEdits: true))
        XCTAssertNil(NotificationCategories.answer(for: "OPEN"))
        XCTAssertNil(NotificationCategories.answer(for: UNNotificationDefaultActionIdentifier))
    }
}
