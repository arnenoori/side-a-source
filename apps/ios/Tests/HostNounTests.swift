import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import XCTest
@testable import SideARemote

/// What the phone calls the computer behind a host: a Mac keeps the words it had, anything else is a computer.
@MainActor
final class HostNounTests: XCTestCase {
    func testAMacKeepsEveryWordItHad() {
        let mac = HostOS.macos
        XCTAssertEqual([mac.noun, mac.titleNoun, mac.plural, mac.titlePlural], ["Mac", "Mac", "Macs", "Macs"])
        XCTAssertEqual([mac.the(), mac.your(), mac.sentenceThe()], ["the Mac", "your Mac", "The Mac"])
        // The host's name never replaces "Mac" for a Mac.
        XCTAssertEqual([mac.the("Studio"), mac.your("Studio"), mac.sentenceThe("Studio")], ["the Mac", "your Mac", "The Mac"])
        XCTAssertEqual("\(mac.titleNoun)'s Screen", "Mac's Screen")
        XCTAssertEqual("Forget This \(mac.titleNoun)", "Forget This Mac")
    }

    func testAnyOtherHostIsAComputerOrItsOwnName() {
        for kind in [HostOS.linux, .windows, .wsl, HostOS(rawValue: "haiku")] {
            XCTAssertEqual([kind.noun, kind.titleNoun, kind.plural, kind.titlePlural], ["computer", "Computer", "computers", "Computers"])
            XCTAssertEqual([kind.the(), kind.your(), kind.sentenceThe()], ["the computer", "your computer", "The computer"])
            XCTAssertEqual([kind.the("build-box"), kind.your("build-box"), kind.sentenceThe("build-box")], ["build-box", "build-box", "build-box"])
            XCTAssertEqual(kind.the(""), "the computer")
        }
        XCTAssertEqual("\(HostOS.linux.titleNoun)'s Screen", "Computer's Screen")
    }

    func testHostsTogetherAreMacsOnlyWhenEveryOneIs() {
        XCTAssertEqual([HostOS]().shared, .macos)
        XCTAssertEqual([HostOS.macos, .macos].shared, .macos)
        XCTAssertEqual([HostOS.macos, .linux].shared.titlePlural, "Computers")
        XCTAssertEqual([HostOS.linux, .windows].shared, .linux)
    }

    func testTheSuperKeyIsWhatTheHostCallsIt() {
        XCTAssertEqual([HostOS.macos, .linux, .windows, .wsl].map(\.superKeyName), ["Command", "Super", "Win", "Win"])
    }

    func testAPairingSavedBeforeHostsSaidIsAMacAndKeepsItsKindThroughAHello() throws {
        let old = Endpoint(macID: "m", baseURL: try XCTUnwrap(URL(string: "https://100.1.2.3:47800")), serverKeyHash: "k", name: "Studio")
        XCTAssertNil(old.os)
        XCTAssertEqual(old.kind, .macos)
        // Saved JSON from before `os` decodes, and a hello that names no kind changes nothing.
        let saved = try JSONEncoder().encode(old)
        XCTAssertEqual(try JSONDecoder().decode(Endpoint.self, from: saved), old)
        XCTAssertEqual(old.updated(os: nil), old)
        let linux = old.updated(os: .linux)
        XCTAssertEqual(linux.kind, .linux)
        XCTAssertEqual(linux.updated(os: nil).kind, .linux)
        XCTAssertEqual(try JSONDecoder().decode(Endpoint.self, from: JSONEncoder().encode(linux)).os, .linux)
        XCTAssertEqual(linux.updated(with: Endpoints(tailnet: "100.9.9.9:47800")).os, .linux)
    }

    func testARefusalThatCameAsACloseCodeIsWordedForTheHost() {
        XCTAssertEqual(ScreenModel.words(.timeout, .linux), "The computer stopped hearing from this \(ThisDevice.kind).")
        XCTAssertEqual(ScreenModel.words(.permission, .macos), ScreenRefusal.permission.message)
        XCTAssertEqual(ScreenModel.words(.off, .windows), "Screen sharing is off on the computer.")
    }

    func testTheWordsAboutAScreenAreTheMacsOnlyForAMac() {
        let stop = ScreenModel.Stop.permission("Allow it")
        XCTAssertEqual(ScreenScreen.describe(stop, mac: "Studio").0, "Screen Recording Not Allowed")
        XCTAssertEqual(ScreenScreen.describe(stop, mac: "build-box", kind: .linux).0, "Screen Capture Not Allowed")
        XCTAssertEqual(ScreenScreen.why(.accessibility, mac: "Studio"), "Allow Side A in Accessibility on Studio to click")
        XCTAssertEqual(ScreenScreen.why(.accessibility, mac: "build-box", kind: .linux), "Side A can't click on build-box")
    }

    func testAHostConnectionStartsAsAMacAndTakesItsKind() {
        let connection = MacConnection(name: "Studio", state: .connecting, lastSeen: .now)
        XCTAssertEqual(connection.kind, .macos)
        connection.kind = .linux
        XCTAssertEqual(connection.kind.the(connection.name), "Studio")
    }
}
