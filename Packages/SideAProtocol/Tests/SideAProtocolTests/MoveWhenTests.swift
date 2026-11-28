import Foundation
import SideAProtocol
import SideAProtocolFixtures
import Testing

@Test func aMoveRequestWithoutWhenIsTheIdleMoveAnOlderPhoneSends() throws {
    let old = try JSONDecoder().decode(MoveRequest.self, from: Fixtures.data("MoveRequest.computer"))
    #expect(old.when == nil && old.computer == "9c1e7b3d4f2a5b6c")
    // Omitted, never null: an older host re-encodes it to the same bytes the phone signed.
    #expect(!String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("when"))

    let later = try JSONDecoder().decode(MoveRequest.self, from: Fixtures.data("MoveRequest.after-turn"))
    #expect(later.when == .afterTurn)
    #expect(try JSONDecoder().decode(MoveRequest.self, from: Fixtures.data("MoveRequest.now")).when == .now)
    let future = try JSONDecoder().decode(MoveRequest.self, from: Fixtures.data("future/MoveRequest.unknown-when"))
    #expect(future.when == MoveRequest.When(rawValue: "atLunch"))
    #expect(try JSONDecoder().decode(MoveRequest.self, from: JSONEncoder().encode(future)) == future)
}

@Test func theSignatureOfAMoveCoversWhenItGoes() throws {
    let idle = try ConfirmMessage.subject(action: .moveSession, target: "s1", body: MoveRequest(computer: "mini"))
    let later = try ConfirmMessage.subject(action: .moveSession, target: "s1", body: MoveRequest(computer: "mini", when: .afterTurn))
    let now = try ConfirmMessage.subject(action: .moveSession, target: "s1", body: MoveRequest(computer: "mini", when: .now))
    #expect(Set([idle, later, now]).count == 3)
}

@Test func aWaitingMoveIsListedAsWaiting() throws {
    let list = try JSONDecoder().decode(MoveList.self, from: Fixtures.data("MoveList.waiting"))
    #expect(list.moves.map(\.state) == [.waiting] && list.moves.first?.session == nil)
    #expect(Capability.movesWhen.rawValue == "moves.when")
}
