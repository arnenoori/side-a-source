import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import Testing

private let rid = "5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b"

private func live(_ mac: FakeMac, outbox: Outbox) async throws -> (SyncEngine, FakeSocket) {
    let sync = try engine(mac, outbox: outbox)
    await sync.start()
    let socket = try await mac.socket(0)
    try socket.push(fixture: "ServerEvent.welcome")
    try socket.push(fixture: "ServerEvent.snapshot")
    try await until("snapshot") { await sync.state.seq == 41 }
    return (sync, socket)
}

/// A Mac whose `IdempotencyStore` keeps every answer it gives, as one from before refusals stopped being stored.
private final class Replaying: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: FakeMac.Reply] = [:]
    func reply(_ key: String, first: FakeMac.Reply) -> FakeMac.Reply {
        lock.withLock {
            if let known = stored[key] { return known }
            stored[key] = first
            return first
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.withLock { defer { used = true }; return !used } }
}

// MARK: Answers

/// The audit's trace: refused, the request reopens, and the second tap lands under a key of its own, whatever the Mac
/// stored for the first.
@Test func aTapAfterARefusalGoesUnderItsOwnKeyAndSettlesAlone() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    let refused = json(ErrorBody(error: APIError(code: ErrorCode(rawValue: "invalid"), message: "No.", retryable: false)))
    let replaying = Replaying()
    let answered = try Fixtures.data("RequestResolution.device")
    mac.respond { request in
        let key = request.value(forHTTPHeaderField: "Idempotency-Key") ?? ""
        return replaying.reply(key, first: key == "\(rid):allow" ? .init(status: 422, body: refused) : .init(body: answered))
    }
    let (sync, _) = try await live(mac, outbox: outbox)

    let first = await sync.answer(rid, .allow(confirmDestructive: false))
    #expect(first.id == "\(rid):allow")
    try await until("refused") { await sync.state.outcomes[first.id] != nil }
    #expect(await sync.state.requests[rid] != nil)

    let second = await sync.answer(rid, .allow(confirmDestructive: false))
    #expect(second.id != first.id && second.id.hasPrefix("\(rid):allow:a") && second.id.count <= 128)
    #expect(await sync.state.outcomes[second.id] == nil)
    try await until("delivered") { await sync.state.outcomes[second.id] == .delivered(answered) }
    if case .failed? = await sync.state.outcomes[first.id] {} else { Issue.record("the first attempt's refusal stays its own") }
    #expect(await sync.state.requests[rid] == nil)

    let third = await sync.answer(rid, .allow(confirmDestructive: false))
    #expect(third.id != second.id)
    await sync.stop()
}

@Test func aTapAfterAnUnknownOutcomeGetsItsOwnKeyAndADeliveredOneReplays() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    let unknown = json(ErrorBody(error: APIError(code: .outcomeUnknown, message: "Side A quit.")))
    let answered = try Fixtures.data("RequestResolution.device")
    mac.respond { request in
        request.value(forHTTPHeaderField: "Idempotency-Key") == "\(rid):allow" ? .init(status: 409, body: unknown) : .init(body: answered)
    }
    let (sync, _) = try await live(mac, outbox: outbox)
    _ = await sync.answer(rid, .allow(confirmDestructive: false))
    try await until("unknown") { await sync.state.outcomes["\(rid):allow"] == .unknown }
    let again = await sync.answer(rid, .allow(confirmDestructive: false))
    #expect(again.id != "\(rid):allow")

    let deny = await sync.answer(rid, .deny(message: nil))
    try await until("denied") { await sync.state.outcomes[deny.id] != nil }
    #expect(deny.id == "\(rid):deny")
    #expect(await sync.answer(rid, .deny(message: nil)).id == "\(rid):deny")
    await sync.stop()
}

// MARK: Reply flights

private let body = RemoteReply(text: "Ship it", mode: .note, attachments: ["up1"], submit: .steer)

@Test func aFlightsNextStepFollowsItsPhase() {
    let required = APIError(code: .confirmRequired, message: "Confirm with Face ID on your iPhone.", details: ["level": "biometric"])
    var flight = ReplyFlight(session: "s", turn: "t", body: body, at: 1, phase: .queued(resigned: false))
    #expect(flight.next(after: .failed(required)) == .resign(.biometric))
    #expect(flight.next(after: .unknown) == .unsent(reason: "The Mac may not have it."))
    #expect(flight.next(after: .notDelivered) == .unsent(reason: "The Mac couldn't be reached."))
    #expect(flight.next(after: .answeredElsewhere(nil)) == .delivered(nil))
    #expect(flight.next(after: .delivered(Data("x".utf8))) == .delivered(Data("x".utf8)))
    // A second refusal stands; so does one that needs a new pairing, which no signature here can answer.
    flight.phase = .queued(resigned: true)
    #expect(flight.next(after: .failed(required)) == .unsent(reason: required.message))
    flight.phase = .queued(resigned: false)
    let pair = APIError(code: .confirmRequired, message: "Pair this iPhone again.", details: ["hint": "pairAgain"])
    #expect(flight.next(after: .failed(pair)) == .unsent(reason: pair.message))
}

@Test func aFlightReadBackAfterAKillIsNeverStuckMidway() {
    func phase(_ phase: ReplyFlight.Phase, inQueue: Bool) -> ReplyFlight.Phase {
        ReplyFlight(session: "s", turn: "t", body: body, at: 1, phase: phase).restored(inQueue: inQueue)
    }
    #expect(phase(.signing, inQueue: false) == .unsent(reason: "Not confirmed."))
    #expect(phase(.resigning, inQueue: false) == .unsent(reason: "Not confirmed."))
    #expect(phase(.queued(resigned: false), inQueue: false) == .unsent(reason: "The Mac may not have it."))
    #expect(phase(.queued(resigned: true), inQueue: true) == .queued(resigned: true))
    // Killed between queueing it and recording that.
    #expect(phase(.signing, inQueue: true) == .queued(resigned: false))
    #expect(phase(.resigning, inQueue: true) == .queued(resigned: true))
    #expect(phase(.unsent(reason: "No."), inQueue: false) == .unsent(reason: "No."))

    let old = ReplyFlight(session: "s", turn: "t", body: body, at: 0, phase: .unsent(reason: "No."))
    #expect(old.expired(now: ReplyFlight.unsentLifetime + 1) && !old.expired(now: 1))
    #expect(!ReplyFlight(session: "s", turn: "t", body: body, at: 0, phase: .queued(resigned: false)).expired(now: ReplyFlight.unsentLifetime + 1))
}

@Test func flightsOutliveTheProcessAndStayWithTheirMac() async throws {
    let (outbox, file) = try temporaryOutbox()
    let flight = ReplyFlight(session: "s", turn: "t", body: body, at: 1, phase: .unsent(reason: "No."), needs: .biometric)
    await outbox.setFlight(flight, item: "a", mac: "mac1")
    await outbox.setFlight(flight, item: "b", mac: "mac2")
    let again = try Outbox(file: file)
    #expect(await again.flights(for: "mac1") == ["a": flight])
    await again.setFlight(nil, item: "a", mac: "mac1")
    #expect(await outbox.flights(for: "mac1").isEmpty)
    await outbox.removeFlights(for: "mac2")
    #expect(await again.flights(for: "mac2").isEmpty)
}

@Test func aReplyGoesUnderTheKeyItsFlightRecorded() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    mac.respond { _ in .init(body: json(ReplyResult(delivery: .note, sessionID: "s"))) }
    let (sync, _) = try await live(mac, outbox: outbox)
    let item = await sync.reply("s", body, id: "flight-key")
    #expect(item.id == "flight-key")
    try await until("sent") { await sync.state.outcomes["flight-key"] != nil }
    #expect(mac.calls.last?.value(forHTTPHeaderField: "Idempotency-Key") == "flight-key")
    await sync.stop()
}

// MARK: The engine's loop

/// The stopped run's socket closes late, after the next run has its own: that close is no business of the new socket.
@Test func aHaltedRunsLateCloseLeavesTheNewSocketAlone() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let old = try await mac.socket(0)
    old.holdClose()
    old.push(nil, welcome("e", seq: 0, replay: false))
    try await until("live") { await sync.state.connection.isLive }

    await sync.stop()
    await sync.start()
    let new = try await mac.socket(1)
    new.push(nil, welcome("e", seq: 0, replay: false))
    try await until("live again") { await sync.state.connection.isLive }

    old.serverClose(1006)
    try await Task.sleep(for: .milliseconds(100))
    #expect(await sync.state.connection.isLive)
    await sync.setViewing("watched")
    #expect(new.sent.contains(.presence(foreground: true, viewing: "watched")))

    // Still this run's generation, so a ping that goes unanswered is noticed.
    new.failPings(URLError(.networkConnectionLost))
    await sync.setForeground(true)
    try await until("noticed") { new.closedByClient == 4008 }
    await sync.stop()
}

// MARK: The outbox's drain

@Test func anItemQueuedAsTheLastClaimCameBackEmptyStillGoes() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    let answered = try Fixtures.data("RequestResolution.device")
    mac.respond { _ in .init(body: answered) }
    let (sync, _) = try await live(mac, outbox: outbox)
    let late = Outbox.Item(id: "late", macID: "mac1", path: "/v1/sessions/s/interrupt", createdAt: 1, expiresAt: 9_999_999_999)
    let once = Once()
    await sync.setAfterEmptyClaim { [weak sync] in
        guard once.take() else { return }
        await outbox.enqueue(late)
        await sync?.drain()
    }
    await sync.answer(rid, .deny(message: nil))
    try await until("the late item went") { await sync.state.outcomes["late"] == .delivered(answered) }
    await sync.stop()
}
