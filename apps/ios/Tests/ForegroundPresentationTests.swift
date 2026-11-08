import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import UserNotifications
import XCTest
@testable import SideARemote

@MainActor
final class ForegroundPresentationTests: XCTestCase {
    private let payload = PushPayload(t: "request", mac: "m1", sent: 0, rid: "r1", sid: "s1", title: "Allow Bash")

    func testOpenAndLiveToThatMacStaysQuiet() {
        XCTAssertEqual(AppDelegate.presentation(for: payload, active: true, live: ["m1"]), [])
    }

    func testAnotherMacOrNoLiveLinkStillBanners() {
        XCTAssertEqual(AppDelegate.presentation(for: payload, active: true, live: ["m2"]), [.banner, .list, .sound])
        XCTAssertEqual(AppDelegate.presentation(for: payload, active: true, live: []), [.banner, .list, .sound])
    }

    private final class Silent: Transport, @unchecked Sendable {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
        func socket(_ request: URLRequest) -> any SocketConnection { fatalError("no socket") }
    }

    private func link(_ macID: String) throws -> LiveLink {
        let endpoint = Endpoint(macID: macID, baseURL: URL(string: "https://100.64.0.9:47800")!, serverKeyHash: "k", name: "Studio")
        let outbox = try Outbox(file: FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).sqlite"))
        return LiveLink(mac: PairedMac(endpoint: endpoint, deviceID: "d", deviceName: "iPhone"), outbox: outbox, transport: Silent())
    }

    private func live(_ link: LiveLink, _ on: Bool) {
        var state = link.state
        state.connection = on ? .live(since: 0) : .offline(retryAt: 0, reason: "gone")
        link.apply(state)
    }

    /// A Mac is live while a link's socket is: stopping or replacing the link takes it out at once, and an old link
    /// stopping after its replacement went live leaves the new one live.
    func testALinkIsLiveUntilItDropsStopsOrIsReplaced() throws {
        let mac = "live-\(UUID().uuidString)"
        let first = try link(mac)
        live(first, true)
        XCTAssertTrue(LiveLink.liveMacs.contains(mac))
        live(first, false)
        XCTAssertFalse(LiveLink.liveMacs.contains(mac))
        live(first, true)
        first.stop()
        XCTAssertFalse(LiveLink.liveMacs.contains(mac), "stopped")
        live(first, true)
        XCTAssertFalse(LiveLink.liveMacs.contains(mac), "a state after stop")

        let old = try link(mac), replacement = try link(mac)
        live(old, true)
        live(replacement, true)
        old.stop()
        XCTAssertTrue(LiveLink.liveMacs.contains(mac), "the replacement's")
        live(old, false)
        XCTAssertTrue(LiveLink.liveMacs.contains(mac))
        replacement.stop()
        XCTAssertFalse(LiveLink.liveMacs.contains(mac))
    }

    func testInactiveOrUnreadableStillBanners() {
        XCTAssertEqual(AppDelegate.presentation(for: payload, active: false, live: ["m1"]), [.banner, .list, .sound])
        XCTAssertEqual(AppDelegate.presentation(for: nil, active: true, live: ["m1"]), [.banner, .list, .sound])
    }
}
