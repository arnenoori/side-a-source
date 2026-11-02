import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import XCTest
@testable import SideARemote

/// Several paired Macs: the keychain list and its migration, Forget for one Mac, the tailnet warning,
/// and the widgets across Macs.
@MainActor
final class MultiMacTests: XCTestCase {
    private let keychain = SharedKeychain.shared
    private let accounts = ["mac", "macs", "revoke", "token.m1", "token.m2", "secret.m1", "secret.m2", "pushKey.m1", "pushKey.m2"]
    private var saved: [String: Data] = [:]

    override func setUp() async throws {
        for account in accounts {
            if let data = keychain.data(account) { saved[account] = data }
            keychain.set(nil, for: account)
        }
    }

    override func tearDown() async throws {
        for account in accounts { keychain.set(saved[account], for: account) }
    }

    func testACodeThatMayNotBeFromItsMacWarns() throws {
        XCTAssertTrue(keychain.set(try JSONEncoder().encode([mac("m1", tailnet: nil)]), for: "macs"))
        func invitation(fp: String, name: String?, id: String) -> PairingClient.Invitation {
            PairingClient.Invitation(address: "100.64.0.9:47800", fp: fp, macName: name, macID: id, code: "ABCD")
        }
        XCTAssertNil(PairedMac.identityWarning(invitation(fp: "km1", name: "MacBook Pro", id: "m1")), "Pair Again")
        XCTAssertNil(PairedMac.identityWarning(invitation(fp: "other", name: "Mac mini", id: "m9")), "another Mac")
        XCTAssertNotNil(PairedMac.identityWarning(invitation(fp: "evil", name: "MacBook Pro", id: "m1")), "the pin changes")
        XCTAssertNotNil(PairedMac.identityWarning(invitation(fp: "evil", name: "macbook pro ", id: "m9")), "a paired Mac's name")
    }

    private func mac(_ id: String, tailnet: String?, relay: Bool = false) -> PairedMac {
        PairedMac(endpoint: Endpoint(macID: id, baseURL: URL(string: "https://100.64.0.\(id.suffix(1)):47800")!, serverKeyHash: "k\(id)",
                                     name: id == "m1" ? "MacBook Pro" : "Mac mini"),
                  deviceID: "d\(id)", deviceName: "iPhone", relayInstallID: relay ? "i\(id)" : nil,
                  relayURL: relay ? "https://relay.example" : nil, tailnet: tailnet)
    }

    private func store(_ macs: [PairedMac]) {
        keychain.set(try? JSONEncoder().encode(macs), for: "macs")
    }

    func testTheOneMacPairedBeforeMultiMacMovesIntoTheList() throws {
        keychain.set(try JSONEncoder().encode(mac("m1", tailnet: "a.ts.net")), for: "mac")
        XCTAssertEqual(PairedMac.all().map(\.endpoint.macID), ["m1"])
        XCTAssertNil(keychain.data("mac"))
        XCTAssertEqual(PairedMac.load("m1")?.endpoint.name, "MacBook Pro")
    }

    func testForgetRemovesOnlyThatMacAndKeepsItsTokenForTheRevocation() {
        store([mac("m1", tailnet: nil), mac("m2", tailnet: nil)])
        keychain.set(Data("t1".utf8), for: "token.m1")
        keychain.set(Data("t2".utf8), for: "token.m2")
        PairedMac.load("m1")?.forget()
        XCTAssertEqual(PairedMac.all().map(\.endpoint.macID), ["m2"])
        XCTAssertEqual(Revocations.pending().map(\.mac.endpoint.macID), ["m1"])
        XCTAssertEqual(Revocations.pending().first?.token, "t1")
        XCTAssertNotNil(keychain.data("token.m2"))
    }

    func testPairingTheSameMacAgainCancelsItsRevocation() {
        store([mac("m1", tailnet: nil)])
        keychain.set(Data("t1".utf8), for: "token.m1")
        PairedMac.load("m1")?.forget()
        Revocations.cancel("m1")
        XCTAssertTrue(Revocations.pending().isEmpty)
    }

    func testDifferentTailnetsWarnOnlyWithoutTheRelay() {
        store([mac("m1", tailnet: "home.ts.net")])
        let other = PairingClient.Invitation(address: "100.64.0.2:47800", fp: "f", macName: "Mac mini", macID: "m2",
                                             tailnet: "work.ts.net", code: "ABCD2345")
        let same = PairingClient.Invitation(address: "100.64.0.2:47800", fp: "f", macName: "Mac mini", macID: "m2",
                                            tailnet: "home.ts.net", code: "ABCD2345")
        XCTAssertEqual(PairedMac.otherTailnet(other)?.endpoint.macID, "m1")
        XCTAssertNil(PairedMac.otherTailnet(same))
        store([mac("m1", tailnet: "home.ts.net", relay: true)])
        XCTAssertNil(PairedMac.otherTailnet(other))
    }

    func testPairAgainReplacesOnlyTheSameMac() {
        store([mac("m1", tailnet: nil)])
        let again = PairingClient.Invitation(address: "100.64.0.1:47800", fp: "f", macID: "m1", code: "ABCD2345")
        let another = PairingClient.Invitation(address: "100.64.0.2:47800", fp: "f", macID: "m2", code: "ABCD2345")
        XCTAssertEqual(PairedMac.matching(again)?.endpoint.macID, "m1")
        XCTAssertNil(PairedMac.matching(another))
    }

    func testWidgetsAddUpEveryMacAndLinkEachRowToItsMac() {
        let first = AppModel.demo(), second = AppModel.demoSecond()
        let snapshot = WidgetSnapshot([first, second])
        XCTAssertEqual(snapshot.macName, "2 Macs")
        XCTAssertEqual(snapshot.working, first.sessions.rows(.working).count + second.sessions.rows(.working).count)
        let mini = try? XCTUnwrap(snapshot.sessions.first { $0.id == "mini-backup" })
        XCTAssertEqual(mini?.mac, "demo-2")
        XCTAssertEqual(snapshot.sessionURL("mini-backup"), URL(string: "sidea-remote://session/demo-2/mini-backup"))
        // Work is signed in on both Macs and shows once.
        XCTAssertEqual(snapshot.accounts.filter { $0.id == "work" }.count, 1)
    }

    func testTheRootFindsEachSessionsMac() {
        let root = AppRoot(arguments: ["--demo", "--demo-macs", "2"])
        XCTAssertEqual(root.macs.count, 2)
        XCTAssertEqual(root.model(owning: "mini-backup")?.mac.name, "Mac mini")
        XCTAssertEqual(root.model(owning: DemoData.ID.syncTest)?.mac.name, "MacBook Pro")
        root.shown = "demo-2"
        XCTAssertEqual(root.visible.map(\.macID), ["demo-2"])
        XCTAssertEqual(root.current.mac.name, "Mac mini")
    }
}
