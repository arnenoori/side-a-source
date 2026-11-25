import XCTest
@testable import SideARemote

@MainActor
final class ShownConnectionTests: XCTestCase {
    /// A blip of reconnecting keeps the green chip for `blip`; every line of text beside it has to keep saying it is connected.
    func testABlipOfReconnectingNeverReadsReconnectingBesideTheGreenChip() async {
        let mac = MacConnection(name: "Studio", state: .live, lastSeen: .now)
        mac.route = .wifi
        mac.state = .reconnecting(since: .now)
        XCTAssertEqual(mac.shown, .live)
        XCTAssertEqual(mac.status, "Connected via Wi\u{2011}Fi")

        for _ in 0..<400 where mac.shown == .live {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(mac.shown, mac.state)
        XCTAssertEqual(mac.status, mac.state.title)
    }

    func testAnOfflineMacShowsItAtOnce() {
        let mac = MacConnection(name: "Studio", state: .live, lastSeen: .now)
        mac.state = .offline(.macUnreachable)
        XCTAssertEqual(mac.status, mac.state.title)
    }
}
