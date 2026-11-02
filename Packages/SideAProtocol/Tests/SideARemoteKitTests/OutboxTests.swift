import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import Testing

private let rid = "5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b"

@Test func itemsSurviveANewOutboxOnTheSameFile() async throws {
    let (outbox, file) = try temporaryOutbox()
    let item = Outbox.Item(id: "\(rid):allow", macID: "mac1", path: "/v1/requests/\(rid)/answer", body: Data("{}".utf8), createdAt: 1, expiresAt: 2)
    await outbox.enqueue(item)
    await outbox.enqueue(item)
    await outbox.enqueue(Outbox.Item(id: "b", macID: "mac2", path: "/v1/sessions/s/interrupt", createdAt: 0, expiresAt: 2))
    // Another process opening the same file sees the same queue.
    let again = try Outbox(file: file)
    #expect(await again.items(for: "mac1") == [item])
    #expect(item.answering == rid)
    var tried = item
    tried.attempts = 2
    await again.update(tried)
    #expect(await outbox.items(for: "mac1").first?.attempts == 2)
    await outbox.remove(item.id)
    #expect(await again.items(for: "mac1").isEmpty)
    #expect(await again.items(for: "mac2").count == 1)
}

/// Opens a live engine on a snapshot holding the fixture request.
private func live(_ mac: FakeMac, outbox: Outbox) async throws -> (SyncEngine, FakeSocket) {
    let sync = try engine(mac, outbox: outbox)
    await sync.start()
    let socket = try await mac.socket(0)
    try socket.push(fixture: "ServerEvent.welcome")
    try socket.push(fixture: "ServerEvent.snapshot")
    try await until("snapshot") { await sync.state.seq == 41 }
    return (sync, socket)
}

@Test func anAnswerIsOptimisticAndDeliveredWithItsKey() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    mac.respond { _ in .init(status: 503) }
    let (sync, _) = try await live(mac, outbox: outbox)
    let item = await sync.answer(rid, .allow(confirmDestructive: false))
    #expect(item.id == "\(rid):allow")
    // Hidden while pending, even though the Mac hasn't confirmed.
    let optimistic = await sync.state
    #expect(optimistic.requests[rid] == nil && optimistic.pending.map(\.id) == [item.id])
    try await until("retries") { mac.calls.count >= 3 }
    #expect(Set(mac.calls.map { $0.value(forHTTPHeaderField: "Idempotency-Key") }) == [item.id])
    #expect(String(decoding: mac.calls[0].httpBody ?? Data(), as: UTF8.self) == #"{"answer":{"confirmDestructive":false,"kind":"allow"}}"#)
    #expect(await outbox.items(for: "mac1").first?.attempts ?? 0 >= 2)

    let resolution = try Fixtures.data("RequestResolution.device")
    mac.respond { _ in .init(body: resolution) }
    try await until("delivered") { await sync.state.outcomes[item.id] == .delivered(resolution) }
    #expect(await sync.state.pending.isEmpty)
    // The response came before the request's resolve event: it doesn't reappear as waiting in between.
    #expect(await sync.state.requests[rid] == nil)
    #expect(await outbox.items(for: "mac1").isEmpty)
    await sync.stop()
}

@Test func alreadyResolvedAndOtherRefusalsLeaveTheQueue() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    let resolved = json(ErrorBody(error: APIError(code: .alreadyResolved, message: "Answered on the Mac.", details: ["by": "mac"])))
    mac.respond { request in
        request.url!.path.hasSuffix("/answer") ? .init(status: 409, body: resolved)
            : .init(status: 409, body: json(ErrorBody(error: APIError(code: .sessionWaiting, message: "Answer the prompt first."))))
    }
    let (sync, _) = try await live(mac, outbox: outbox)
    let answer = await sync.answer(rid, .deny(message: nil))
    let reply = await sync.reply("s", RemoteReply(text: "go on"))
    try await until("outcomes") { await sync.state.outcomes.count == 2 }
    let state = await sync.state
    #expect(state.outcomes[answer.id] == .answeredElsewhere(nil))
    #expect(state.outcomes[reply.id] == .failed(APIError(code: .sessionWaiting, message: "Answer the prompt first.")))
    // Settled on the Mac: never back in the list as waiting while its event is on the way.
    #expect(state.requests[rid] == nil && state.pending.isEmpty)
    await sync.stop()
}

@Test func aResolutionFromTheMacDropsAPendingAnswer() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    mac.respond { _ in .init(status: 0) }
    let (sync, socket) = try await live(mac, outbox: outbox)
    let item = await sync.answer(rid, .allow(confirmDestructive: false))
    let resolution = RequestResolution(requestID: rid, by: .terminal, at: 5)
    socket.push(42, .requestResolve(resolution))
    try await until("answered elsewhere") { await sync.state.outcomes[item.id] == .answeredElsewhere(resolution) }
    try await until("removed") { await outbox.items(for: "mac1").isEmpty }
    let state = await sync.state
    #expect(state.resolved[rid] == resolution && state.requests.isEmpty)
    await sync.stop()
}

@Test func anExpiredItemIsNotDelivered() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    await outbox.enqueue(Outbox.Item(id: "old", macID: "mac1", path: "/v1/sessions/s/interrupt", createdAt: 0, expiresAt: 1))
    let (sync, _) = try await live(mac, outbox: outbox)
    try await until("dropped") { await sync.state.outcomes["old"] == .notDelivered }
    #expect(mac.calls.isEmpty)
    await sync.stop()
}

@Test func unauthorizedStopsDraining() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    mac.respond { _ in .init(status: 401, body: json(ErrorBody(error: APIError(code: .unauthorized, message: "Pair again.")))) }
    let (sync, _) = try await live(mac, outbox: outbox)
    let item = await sync.interrupt("s")
    try await until("unpaired") { await sync.state.connection == .unpaired }
    #expect(await outbox.items(for: "mac1").map(\.id) == [item.id])
}

@Test func twoProcessesEnqueueingAtOnceLoseNothingAndNeverClaimTheSameItem() async throws {
    let (one, file) = try temporaryOutbox()
    let two = try Outbox(file: file)
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<40 {
            let outbox = index.isMultiple(of: 2) ? one : two
            group.addTask { await outbox.enqueue(Outbox.Item(id: "i\(index)", macID: "mac1", path: "/v1/sessions/s/reply", createdAt: Double(index), expiresAt: 99)) }
        }
    }
    #expect(await one.items(for: "mac1").count == 40)

    // Both drain at once: every item goes to exactly one of them.
    async let a = drainAll(one, owner: "app")
    async let b = drainAll(two, owner: "intent")
    let (claimedByOne, claimedByTwo) = await (a, b)
    #expect(Set(claimedByOne).isDisjoint(with: claimedByTwo) && claimedByOne.count + claimedByTwo.count == 40)

    // A claim older than 30 s is free again: its process died mid-send.
    await one.enqueue(Outbox.Item(id: "stale", macID: "mac1", path: "/v1/sessions/s/reply", createdAt: 0, expiresAt: 99))
    #expect(await one.claim(for: "mac1", by: "dead", now: 1000)?.id == "stale")
    #expect(await two.claim(for: "mac1", by: "live", now: 1010) == nil)
    #expect(await two.claim(for: "mac1", by: "live", now: 1031)?.id == "stale")
}

private func drainAll(_ outbox: Outbox, owner: String) async -> [String] {
    var taken: [String] = []
    while let item = await outbox.claim(for: "mac1", by: owner, now: 1) {
        taken.append(item.id)
        await outbox.remove(item.id)
    }
    return taken
}

@Test func answersAreClaimedFirst() async throws {
    let (outbox, _) = try temporaryOutbox()
    await outbox.enqueue(Outbox.Item(id: "reply", macID: "mac1", path: "/v1/sessions/s/reply", createdAt: 1, expiresAt: 99))
    await outbox.enqueue(Outbox.Item(id: "\(rid):allow", macID: "mac1", path: "/v1/requests/\(rid)/answer", createdAt: 2, expiresAt: 99))
    #expect(await outbox.claim(for: "mac1", by: "app", now: 3)?.id == "\(rid):allow")
}

@Test func anUnknownOutcomeIsNeverRetried() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    let unknown = json(ErrorBody(error: APIError(code: .outcomeUnknown, message: "This may or may not have reached the Mac.")))
    mac.respond { _ in .init(status: 409, body: unknown) }
    let (sync, _) = try await live(mac, outbox: outbox)
    let item = await sync.reply("s", RemoteReply(text: "go on"))
    try await until("unknown") { await sync.state.outcomes[item.id] == .unknown }
    try await Task.sleep(for: .milliseconds(100))
    #expect(mac.calls.count == 1)
    #expect(await outbox.items(for: "mac1").isEmpty)
    await sync.stop()
}

@Test func inProgressIsRetriedButAnUnmarkedServerErrorIsNot() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    let busy = json(ErrorBody(error: APIError(code: .inProgress, message: "Still running.", retryable: true)))
    let broken = json(ErrorBody(error: APIError(code: ErrorCode(rawValue: "internal"), message: "Broke.")))
    mac.respond { request in request.url!.path.hasSuffix("/reply") ? .init(status: 409, body: busy) : .init(status: 500, body: broken) }
    let (sync, _) = try await live(mac, outbox: outbox)
    // In order: the interrupt is refused and dropped, then the reply keeps retrying.
    let interrupt = await sync.interrupt("s")
    let reply = await sync.reply("s", RemoteReply(text: "go on"))
    try await until("dropped") { await sync.state.outcomes[interrupt.id] == .failed(APIError(code: ErrorCode(rawValue: "internal"), message: "Broke.")) }
    try await until("retried") { mac.calls.filter { $0.url!.path.hasSuffix("/reply") }.count >= 3 }
    #expect(await outbox.items(for: "mac1").map(\.id) == [reply.id])
    await sync.stop()
}

@Test func aRetryingItemHoldsBackOnlyItsOwnSession() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    let busy = json(ErrorBody(error: APIError(code: .inProgress, message: "Still running.", retryable: true)))
    mac.respond { request in request.url!.path.contains("/sessions/a/") ? .init(status: 409, body: busy) : .init(status: 200, body: try! Fixtures.data("InterruptResult.escape")) }
    let (sync, _) = try await live(mac, outbox: outbox)
    let first = await sync.reply("a", RemoteReply(text: "go on"))
    let second = await sync.interrupt("a")
    let other = await sync.interrupt("b")
    try await until("other session") { if case .delivered = await sync.state.outcomes[other.id] { true } else { false } }
    try await until("retried") { mac.calls.filter { $0.url!.path.contains("/sessions/a/") }.count >= 3 }
    // Session a's interrupt waits behind its reply, which is all that is retried.
    #expect(mac.calls.allSatisfy { !$0.url!.path.hasSuffix("/sessions/a/interrupt") })
    #expect(await outbox.items(for: "mac1").map(\.id) == [first.id, second.id])
    await sync.stop()
}

@Test func aTappedRetrySendsANewKeyAndKeepsTheFirstAttempt() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    let unknown = json(ErrorBody(error: APIError(code: .outcomeUnknown, message: "This may or may not have reached the Mac.")))
    let resolved = json(ErrorBody(error: APIError(code: .alreadyResolved, message: "Already answered.")))
    mac.respond { request in
        let key = request.value(forHTTPHeaderField: "Idempotency-Key")
        return .init(status: 409, body: key == "\(rid):allow:r2" ? resolved : unknown)
    }
    let (sync, _) = try await live(mac, outbox: outbox)
    let first = await sync.answer(rid, .allow(confirmDestructive: false))
    try await until("unknown") { await sync.state.outcomes[first.id] == .unknown }
    #expect(await sync.retry(itemID: "nothing") == nil)

    let one = try #require(await sync.retry(itemID: first.id))
    #expect(one.id == "\(rid):allow:r1" && one.retryOf == first.id && one.retry == 1)
    #expect(one.path == first.path && one.body == first.body && one.expiresAt - one.createdAt == first.expiresAt - first.createdAt)
    try await until("r1 unknown") { await sync.state.outcomes[one.id] == .unknown }

    // Retrying the retry counts from the first attempt; the first one landed, so this one finds it answered.
    let two = try #require(await sync.retry(itemID: one.id))
    #expect(two.id == "\(rid):allow:r2" && two.retryOf == first.id)
    try await until("answered") { if case .answeredElsewhere = await sync.state.latestOutcome(of: first.id) { true } else { false } }
    let state = await sync.state
    #expect(state.outcomes[first.id] == .unknown && state.retries[first.id] == [one.id, two.id])
    // Only a settled-unknown item can be retried, and only by a tap: nothing was sent again on its own.
    #expect(await sync.retry(itemID: two.id) == nil)
    #expect(mac.calls.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") } == [first.id, one.id, two.id])
    await sync.stop()
}

@Test func aRetriedItemMatchesTheSharedFixture() throws {
    let item = try JSONDecoder().decode(Outbox.Item.self, from: Fixtures.data("kit/OutboxItem.retry"))
    #expect(item.id == "\(rid):allow:r1" && item.retryOf == "\(rid):allow" && item.retry == 1 && item.answering == rid)
    let first = Outbox.Item(id: "\(rid):allow", macID: item.macID, path: item.path, body: item.body, createdAt: 1791560000, expiresAt: 1791646400)
    #expect(first.retried(1, now: item.createdAt) == item)
}

@Test func aTakeBackRightAfterANoteGoesAfterIt() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    let busy = json(ErrorBody(error: APIError(code: .inProgress, message: "Still running.", retryable: true)))
    let replies = Counter()
    mac.respond { request in
        if request.url!.path.hasSuffix("/reply") { return replies.next() < 2 ? .init(status: 409, body: busy) : .init(body: Data("{}".utf8)) }
        return .init(status: 204)
    }
    let (sync, _) = try await live(mac, outbox: outbox)
    let note = await sync.reply("s", RemoteReply(text: "also check the tests"))
    let back = await sync.takeBack(sessionID: "s")
    let again = await sync.takeBack(sessionID: "s")
    #expect(back.id.hasPrefix("s:takeback:") && back.id != again.id && back.method == "DELETE" && back.path == "/v1/sessions/s/mail")
    try await until("taken back") { if case .delivered = await sync.state.outcomes[again.id] { true } else { false } }
    // The note's two refusals and its delivery all come before either Take Back.
    #expect(mac.calls.map { "\($0.httpMethod!) \($0.url!.path)" } == ["POST /v1/sessions/s/reply", "POST /v1/sessions/s/reply", "POST /v1/sessions/s/reply",
                                                                       "DELETE /v1/sessions/s/mail", "DELETE /v1/sessions/s/mail"])
    #expect(mac.calls.last?.value(forHTTPHeaderField: "Idempotency-Key") == again.id)
    if case .delivered = await sync.state.outcomes[note.id] {} else { Issue.record("the note wasn't delivered") }
    await sync.stop()
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
}

@Test func aSignedAnswerCarriesItsConfirmAndARefusedSignatureFailsOnlyThatAnswer() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    let required = json(ErrorBody(error: APIError(code: .confirmRequired, message: "Confirm with Face ID.", details: ["level": "biometric"])))
    let unknown = json(ErrorBody(error: APIError(code: .outcomeUnknown, message: "This may or may not have reached the Mac.")))
    mac.respond { request in
        switch request.value(forHTTPHeaderField: "Idempotency-Key") {
        case "\(rid):allow": .init(status: 401, body: required)
        case "\(rid):deny": .init(status: 409, body: unknown)
        default: .init(body: Data("{}".utf8))
        }
    }
    let (sync, _) = try await live(mac, outbox: outbox)
    let allow = await sync.answer(rid, .allow(confirmDestructive: true), confirm: "v1.1791559200.c.AAAA")
    try await until("refused") { if case .failed(let error) = await sync.state.outcomes[allow.id] { error.code == .confirmRequired } else { false } }
    #expect(mac.calls.first?.value(forHTTPHeaderField: ConfirmSignature.header) == "v1.1791559200.c.AAAA")
    // A refused signature isn't a revoked token: the phone stays paired and connected.
    #expect(await sync.state.connection != .unpaired)

    // A retry signs again; the stale signature never goes out twice.
    let deny = await sync.answer(rid, .deny(message: nil), confirm: "v1.1791559200.u.BBBB")
    try await until("unknown") { await sync.state.outcomes[deny.id] == .unknown }
    let again = try #require(await sync.retry(itemID: deny.id, confirm: "v1.1791559300.u.CCCC"))
    try await until("retried") { await sync.state.outcomes[again.id] != nil }
    #expect(mac.calls.last?.value(forHTTPHeaderField: "Idempotency-Key") == again.id)
    #expect(mac.calls.last?.value(forHTTPHeaderField: ConfirmSignature.header) == "v1.1791559300.u.CCCC")
    await sync.stop()
}
