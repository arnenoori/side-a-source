import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import Testing

@Test func probingSpendsNoCodeAndStartingReusesTheProbe() async throws {
    let mac = FakeMac()
    let pending = try Fixtures.data("PairPending.basic")
    mac.respond { request in request.url!.path == "/v1/pair" ? .init(body: pending) : .init(status: 404) }
    let invitation = PairingClient.Invitation(address: "100.101.12.4:47800", fp: "pin", macName: "MacBook Pro", code: "K7QF-29XM")
    let device = try fixture("PairRequest.qr", as: PairRequest.self).device
    let pairing = PairingClient(invitation: invitation, device: device, transport: mac)
    let info = ClientInfo(version: "1.0", build: 41, system: "iOS 27.0", capabilities: [.events])

    let probe = try await pairing.probe(info: info)
    #expect(probe.hello == hello && probe.serverKeyHash == "pin" && mac.calls.isEmpty)
    #expect(probe.hello.needsUpdate(clientBuild: 41) == nil)

    let attempt = try await pairing.start(probe)
    #expect(attempt.hello == hello && attempt.comparisonCode.count == 6)
    #expect(mac.requests.map { $0.url!.path } == ["/v1/hello", "/v1/pair"])
}

@Test func cancellingVoidsTheAttempt() async throws {
    let mac = FakeMac()
    let pending = try Fixtures.data("PairPending.basic")
    mac.respond { request in request.url!.path == "/v1/pair" ? .init(body: pending) : .init(status: 204) }
    let invitation = PairingClient.Invitation(address: "100.101.12.4:47800", fp: "pin", code: "K7QF-29XM")
    let pairing = PairingClient(invitation: invitation, device: try fixture("PairRequest.qr", as: PairRequest.self).device, transport: mac)
    let attempt = try await pairing.start(info: ClientInfo(version: "1.0", build: 41, system: "iOS 27.0", capabilities: [.events]))
    await pairing.cancel(attempt: attempt)
    let last = try #require(mac.calls.last)
    #expect(last.httpMethod == "DELETE" && last.url?.path == "/v1/pair/\(attempt.pending.attemptID)")
    #expect(last.value(forHTTPHeaderField: "Authorization") == nil && (last.httpBody ?? Data()).isEmpty)
}

@Test func everyLANAddressBecomesAnAlternateInOrder() throws {
    let reported = try fixture("Endpoints.lans", as: Endpoints.self)
    let updated = endpoint.updated(with: reported)
    #expect(updated.addresses.map { $0.host! } == ["100.101.12.4", "192.168.1.20", "10.0.0.7"])
    // An older Mac sends only `lan`.
    let older = endpoint.updated(with: try fixture("Endpoints.lan", as: Endpoints.self))
    #expect(older.addresses.map { $0.host! } == ["100.101.12.4", "192.168.1.20"])
}

@Test func aCodeWithoutTheMacsIdIsRefused() throws {
    // Nothing would tie the answer to a Mac: `wait` couldn't tell a paired Mac's id from any other.
    for fragment in ["v=2&a=100.101.12.4:47800&fp=pin&n=MacBook%20Pro&c=K7QF-29XM", "v=2&a=100.101.12.4:47800&fp=pin&m=&c=K7QF-29XM"] {
        #expect(PairingClient.Invitation(url: try #require(URL(string: "https://getsidea.com/pair#" + fragment))) == nil)
    }
}

@Test func anAnswerFromAnotherMacIsRefused() async throws {
    let pending = try Fixtures.data("PairPending.basic")
    let answer = try Fixtures.data("PairResponse.relay")
    let id = try JSONDecoder().decode(PairResponse.self, from: answer).mac.id
    func waited(named macID: String?) async throws -> PairingClient.Paired {
        let mac = FakeMac()
        mac.respond { request in request.url!.path == "/v1/pair" ? .init(body: pending) : .init(body: answer) }
        let invitation = PairingClient.Invitation(address: "100.101.12.4:47800", fp: "pin", macID: macID, code: "K7QF-29XM")
        let pairing = PairingClient(invitation: invitation, device: try fixture("PairRequest.qr", as: PairRequest.self).device, transport: mac)
        return try await pairing.wait(try await pairing.start(info: ClientInfo(version: "1.0", build: 41, system: "iOS 27.0", capabilities: [.events])))
    }
    #expect(try await waited(named: id).endpoint.macID == id)
    await #expect(throws: PairingClient.WrongMac.self) { try await waited(named: "another-mac") }
    await #expect(throws: PairingClient.WrongMac.self) { try await waited(named: nil) }
}

@Test func anInvitationWithoutAKeyHashIsRefused() throws {
    // Pairing is QR-only: a code without the Mac's key hash can't be paired with.
    for fragment in ["v=2&a=100.101.12.4:47800&c=K7QF-29XM", "v=2&a=100.101.12.4:47800&fp=&c=K7QF-29XM"] {
        #expect(PairingClient.Invitation(url: try #require(URL(string: "https://getsidea.com/pair#" + fragment))) == nil)
    }
}

@Test func anInvitationCarriesEveryLANAddress() throws {
    let url = try #require(URL(string: "https://getsidea.com/pair#v=2&a=192.168.1.20:47800&l=192.168.1.20:47800,10.0.0.7:47800&fp=pin&m=mac1&c=K7QF-29XM"))
    let invitation = try #require(PairingClient.Invitation(url: url))
    #expect(invitation.lans == ["192.168.1.20:47800", "10.0.0.7:47800"] && invitation.lan == "192.168.1.20:47800")
    #expect(invitation.addresses == ["192.168.1.20:47800", "10.0.0.7:47800"])
}

@Test func addressesGetAPortAndBrackets() {
    let given = ["192.168.1.20", "mac.local:8080", "[fe80::1]:47801", "fe80::1", "[fe80::1%en0]", " 100.101.12.4:47800 "]
    #expect(given.map { PairingClient.Invitation(address: $0, fp: "pin", code: "K7QF-29XM").address }
        == ["192.168.1.20:47800", "mac.local:8080", "[fe80::1]:47801", "[fe80::1]:47800", "[fe80::1%25en0]:47800", "100.101.12.4:47800"])
    #expect(URL(string: "https://[fe80::1%25en0]:47800") != nil)
}

@Test func probingFallsBackToEachLANAddressAndRemembersWhichAnswered() async throws {
    let mac = FakeMac()
    let pending = try Fixtures.data("PairPending.basic")
    mac.respond { request in request.url!.path == "/v1/pair" ? .init(body: pending) : .init(status: 404) }
    mac.unreachable(["100.101.12.4", "192.168.1.20"])
    let invitation = PairingClient.Invitation(address: "100.101.12.4:47800", lans: ["192.168.1.20:47800", "10.0.0.7:47800"], fp: "pin", code: "K7QF-29XM")
    let pairing = PairingClient(invitation: invitation, device: try fixture("PairRequest.qr", as: PairRequest.self).device, transport: mac)
    let probe = try await pairing.probe(info: ClientInfo(version: "1.0", build: 41, system: "iOS 27.0", capabilities: [.events]))
    #expect(probe.address.host == "10.0.0.7")
    #expect(mac.requests.map { $0.url!.host! } == ["100.101.12.4", "192.168.1.20", "10.0.0.7"])
    #expect(mac.requests.allSatisfy { $0.timeoutInterval == PairingClient.probeTimeout })
    _ = try await pairing.start(probe)
    #expect(mac.requests.last?.url?.host == "10.0.0.7" && mac.requests.last?.url?.path == "/v1/pair")
}

@Test func aDifferentKeyEndsTheProbe() async throws {
    let mac = FakeMac()
    mac.rekeyed(["100.101.12.4"])
    let invitation = PairingClient.Invitation(address: "100.101.12.4:47800", lans: ["192.168.1.20:47800"], fp: "pin", code: "K7QF-29XM")
    let pairing = PairingClient(invitation: invitation, device: try fixture("PairRequest.qr", as: PairRequest.self).device, transport: mac)
    await #expect(throws: ServerKeyChanged.self) { try await pairing.probe() }
    #expect(mac.requests.isEmpty)
}

