import CryptoKit
import Foundation
@testable import SideAProtocol
import SideAProtocolFixtures
import Testing

private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return encoder
}()

private func object(_ value: some Encodable) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
}

/// What an older Mac sends a newer phone: none of the new fields, and every old one still reads.
@Test func aNewPhoneReadsAnOlderMac() throws {
    let account = try JSONDecoder().decode(RemoteAccount.self, from: Fixtures.data("RemoteAccount.claude"))
    #expect(account.priority == nil && account.allowAuto == nil && account.limited == nil && account.fableOut == nil && account.issue == nil && account.backAt == nil)
    let old = #"{"enabled":true,"decisions":[{"id":"a","at":1,"kind":"moved","title":"Moved","reason":"","sessions":[]}]}"#
    let state = try JSONDecoder().decode(AutopilotState.self, from: Data(old.utf8))
    #expect(state.next == nil && state.held == nil && state.waiting == nil && state.swapAt == nil && state.followFable == nil && state.fableMode == nil)
    #expect(state.decisions.first?.recacheTokens == nil)
    let snapshot = try JSONDecoder().decode(StateSnapshot.self, from: Data(#"{"seq":1,"epoch":"e","sessions":[],"finished":[],"requests":[],"hosted":[],"accounts":[]}"#.utf8))
    #expect(snapshot.autopilot == nil)
    let session = try JSONDecoder().decode(RemoteSession.self, from: Fixtures.data("future/RemoteSession.new-values"))
    #expect(session.limit == nil)
}

/// What a new Mac sends an older phone. The old shapes are spelled out here: a phone keeps reading what it knew, and
/// takes an event it doesn't know for `.unknown`.
@Test func anOldPhoneReadsANewMac() throws {
    struct OldAccount: Decodable { let id, name, email: String; let provider: AgentProvider; let ready, active: Bool; let sessions: Int }
    struct OldDecision: Decodable { let id: String; let at: Double; let kind, title, reason: String; let sessions: [AutopilotDecision.Moved] }
    struct OldState: Decodable { let enabled: Bool; let pending: OldDecision?; let decisions: [OldDecision]; let answersRecommended: Bool? }

    let account = RemoteAccount(id: "a", name: "Work", provider: .claude, ready: true, priority: .last, allowAuto: false, limited: true, fableOut: false,
                                backAt: 9, issue: AccountIssue(kind: .signInEnds, endsAt: 9))
    let read = try JSONDecoder().decode(OldAccount.self, from: encoder.encode(account))
    #expect(read.name == "Work" && read.sessions == 0)

    let hold = AutopilotDecision(id: "h", at: 1, kind: .priorityWait, title: "Holding", reason: "", recacheTokens: 5)
    let state = AutopilotState(enabled: true, pending: hold, decisions: [hold], answersRecommended: false, held: [hold],
                               next: [NextMove(id: "a", from: "Work", to: "Personal", atPercent: 95, minutes: 40)],
                               waiting: WaitingSummary(account: "Work", at: 9), swapAt: 95, followFable: true, fableMode: false)
    let old = try JSONDecoder().decode(OldState.self, from: encoder.encode(state))
    #expect(old.enabled && old.decisions.first?.kind == "priorityWait" && old.pending?.id == "h")

    // A kind the phone has no case for still decodes.
    #expect(try JSONDecoder().decode(AutopilotDecision.self, from: encoder.encode(hold)).kind.rawValue == "priorityWait")

    // The event's envelope, as a build without the case sees it.
    let frame = try encoder.encode(EventEnvelope(seq: 7, at: 1, event: .autopilotUpdate(state)))
    let text = String(decoding: frame, as: UTF8.self).replacingOccurrences(of: "autopilot.update", with: "autopilot.tomorrow")
    let future = try JSONDecoder().decode(EventEnvelope.self, from: Data(text.utf8))
    #expect(future.seq == 7 && future.event == .unknown(type: "autopilot.tomorrow") && !future.event.isState)

    // A phone without the toggle sends no `rotation`: it wants none.
    #expect(try JSONDecoder().decode(NotificationPrefs.self, from: Fixtures.data("future/NotificationPrefs.before-health")).rotation == nil)
}

@Test func anAutopilotUpdateIsAStateEventThatSurvivesTheWire() throws {
    let state = AutopilotState(enabled: false, decisions: [], held: [], next: [], swapAt: 90, followFable: false, fableMode: true)
    let event = ServerEvent.autopilotUpdate(state)
    #expect(event.type == "autopilot.update" && event.isState)
    let decoded = try JSONDecoder().decode(EventEnvelope.self, from: encoder.encode(EventEnvelope(seq: 3, at: 1, event: event)))
    #expect(decoded.event == event)
    let snapshot = StateSnapshot(seq: 1, epoch: "e", autopilot: state)
    #expect(try JSONDecoder().decode(StateSnapshot.self, from: encoder.encode(snapshot)).autopilot == state)
}

@Test func priorityStaysOpenAndAccountsRoundTrip() throws {
    let unknown = try JSONDecoder().decode(PriorityChange.self, from: Data(#"{"priority":"sometimes"}"#.utf8))
    #expect(unknown.priority.rawValue == "sometimes")
    let account = RemoteAccount(id: "a", name: "W", provider: .claude, ready: true, priority: .first, allowAuto: true, limited: false, fableOut: true, backAt: 2,
                                issue: AccountIssue(kind: .replaced, replacedBy: "Other"))
    #expect(try JSONDecoder().decode(RemoteAccount.self, from: encoder.encode(account)) == account)
    let session = RemoteSession(id: "s", agent: .claude, title: "t", project: "p", status: .idle, limit: SessionLimit(window: "five_hour", accountID: "a", until: 5, worstCase: true))
    #expect(try JSONDecoder().decode(RemoteSession.self, from: encoder.encode(session)).limit == session.limit)
    let outlook = UsageOutlook(rooms: [.init(provider: .claude, accounts: 2, weeklyLeft: 41, runsOut: 9)])
    #expect(try JSONDecoder().decode(UsageOutlook.self, from: encoder.encode(outlook)) == outlook)
}

/// Each subject binds the exact change, so a signature for one never does another.
@Test func rotationSubjectsBindTheChange() throws {
    #expect(try ConfirmMessage.subject(account: "a1", priority: .last) == "a1:priority:last")
    #expect(try ConfirmMessage.subject(account: "a1", auto: false) == "a1:auto:false")
    #expect(ConfirmMessage.subject(swapAt: 90) == "swapAt:90")
    #expect(ConfirmMessage.subject(followFable: true) == "followFable:true")
    #expect(throws: ConfirmMessage.Invalid.self) { try ConfirmMessage.subject(account: "a:1", priority: .last) }
    #expect(throws: ConfirmMessage.Invalid.self) { try ConfirmMessage.subject(account: "a:1", auto: true) }
    #expect(ConfirmPurpose.rotation.rawValue == "rotation")

    let key = P256.Signing.PrivateKey()
    let text = try ConfirmMessage.text(macID: "m", deviceID: "d", purpose: .rotation, subject: "swapAt:90", at: 100)
    let signature = ConfirmSignature(at: 100, signer: .confirm, signature: try key.signature(for: Data(text.utf8)).derRepresentation)
    let pub = key.publicKey.x963Representation.base64URL
    #expect(signature.verify(publicKey: pub, macID: "m", deviceID: "d", purpose: .rotation, subject: "swapAt:90", now: 100))
    #expect(!signature.verify(publicKey: pub, macID: "m", deviceID: "d", purpose: .rotation, subject: "swapAt:95", now: 100))
    #expect(!signature.verify(publicKey: pub, macID: "m", deviceID: "d", purpose: .autopilot, subject: "swapAt:90", now: 100))
    #expect(!signature.verify(publicKey: pub, macID: "m", deviceID: "d2", purpose: .rotation, subject: "swapAt:90", now: 100))
    #expect(!signature.verify(publicKey: pub, macID: "m2", deviceID: "d", purpose: .rotation, subject: "swapAt:90", now: 100))
    #expect(!signature.verify(publicKey: pub, macID: "m", deviceID: "d", purpose: .rotation, subject: "swapAt:90", now: 100 + ConfirmSignature.window + 1))
}

@Test func aRotationPushIsItsOwnCategoryAndNoOtherOpensIt() throws {
    #expect(PushCategory.rotation.rawValue == "ROTATION" && PushCategory.rotation.locKey == "PUSH_ROTATION_FALLBACK")
    let payload = PushPayload(t: "rotation", mac: "m", sent: 1, title: "All out", account: "Work", resetsAt: 5)
    #expect(PushCategory.rotation.local(for: payload) == .rotation)
    let key = PushKey(key: SymmetricKey(size: .bits256), keyID: Data([1, 2, 3, 4]))
    let sealed = try PushEnvelope.seal(try encoder.encode(payload), with: key, category: .rotation, collapseID: "rotation", deviceID: "d")
    #expect(throws: (any Error).self) { try PushEnvelope.open(sealed, with: key, category: .limit, collapseID: "rotation", deviceID: "d") }
    #expect(try object(NotificationPrefs(rotation: true))["rotation"] as? Bool == true)
}
