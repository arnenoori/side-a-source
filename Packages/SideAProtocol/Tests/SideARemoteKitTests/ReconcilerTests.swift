import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import Testing

private let rid = "5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b"

private func snapshot(seq: Int = 41, epoch: String = "e1") throws -> StateSnapshot {
    var event = try #require(JSONSerialization.jsonObject(with: Fixtures.data("ServerEvent.snapshot")) as? [String: Any])
    var data = try #require(event["data"] as? [String: Any])
    data["epoch"] = epoch
    data["seq"] = seq
    event["data"] = data
    guard case .snapshot(let value) = try JSONDecoder().decode(ServerEvent.self, from: JSONSerialization.data(withJSONObject: event)) else {
        throw Timeout(description: "not a snapshot")
    }
    return value
}

private func reconciler(seq: Int = 41, epoch: String = "e1") throws -> Reconciler {
    var value = Reconciler()
    value.apply(try snapshot(seq: seq, epoch: epoch))
    return value
}


private let resolution = RequestResolution(requestID: rid, by: .terminal, at: 5)

@Test func aSnapshotReplacesTheMergedStateAndStartsTheSequenceOver() throws {
    var value = Reconciler()
    value.awaitingSnapshot = true
    value.state.sliceSeq[.requests] = 99
    value.state.queueDrops = ["x": 1]
    value.apply(try snapshot())
    #expect(value.state.seq == 41 && value.state.epoch == "e1" && !value.awaitingSnapshot && value.state.sliceSeq.isEmpty)
    #expect(value.state.sessions.count == 2 && value.state.finished.count == 1 && value.state.hosted.count == 1 && value.state.accounts.count == 1)
    #expect(value.open[rid] != nil && value.state.incidents.isEmpty && value.state.droppedReplies.isEmpty)
    #expect(value.state.queueDrops == ["x": 1], "what no snapshot says is left alone")

    value.apply(StateSnapshot(seq: 3, epoch: "e2"))
    #expect(value.state.seq == 3 && value.state.epoch == "e2" && value.state.sessions.isEmpty && value.open.isEmpty)
}

@Test func anEventIsAppliedOnlyAsTheNextInSequence() throws {
    var value = try reconciler()
    let r1 = value.receive(seq: nil, .hostedRemove(name: "sa-app-3f9c"))
    #expect(r1 == .ignored)
    let r2 = value.receive(seq: 41, .hostedRemove(name: "sa-app-3f9c"))
    #expect(r2 == .ignored)
    let r3 = value.receive(seq: 3, .hostedRemove(name: "sa-app-3f9c"))
    #expect(r3 == .ignored)
    #expect(value.state.hosted.count == 1 && value.state.seq == 41)

    let r4 = value.receive(seq: 43, .hostedRemove(name: "sa-app-3f9c"))
    #expect(r4 == .gap)
    #expect(value.state.hosted.count == 1 && value.state.seq == 41, "a gap changes nothing")

    let r5 = value.receive(seq: 42, .hostedRemove(name: "sa-app-3f9c"))
    #expect(r5 == .applied([]))
    #expect(value.state.hosted.isEmpty && value.state.seq == 42)
}

@Test func nothingIsAppliedWhileASnapshotIsAwaited() throws {
    var value = try reconciler()
    value.welcomed(Welcome(epoch: "e1", seq: 50, replay: false, hello: hello))
    #expect(value.awaitingSnapshot)
    let r6 = value.receive(seq: 42, .hostedRemove(name: "sa-app-3f9c"))
    #expect(r6 == .ignored)
    let r7 = value.receive(seq: 99, .hostedRemove(name: "sa-app-3f9c"))
    #expect(r7 == .ignored, "not a gap either")
    #expect(value.state.seq == 41 && value.state.hosted.count == 1)
    value.apply(StateSnapshot(seq: 50, epoch: "e1"))
    let r8 = value.receive(seq: 51, .hostedRemove(name: "x"))
    #expect(!value.awaitingSnapshot && r8 == .applied([]))
}

@Test func aWelcomeWaitsForASnapshotUnlessItContinuesTheEpoch() throws {
    var value = try reconciler()
    value.welcomed(Welcome(epoch: "e1", seq: 41, replay: true, hello: hello))
    #expect(!value.awaitingSnapshot && value.state.hello == hello)
    value.welcomed(Welcome(epoch: "e2", seq: 41, replay: true, hello: hello))
    #expect(value.awaitingSnapshot, "another epoch is a new world even when it says replay")
    var fresh = Reconciler()
    fresh.welcomed(Welcome(epoch: "e1", seq: 0, replay: true, hello: hello))
    #expect(fresh.awaitingSnapshot, "no epoch held yet")
}

@Test func anEventARestListAlreadyReflectsMovesTheSequenceAndNothingElse() throws {
    var value = try reconciler()
    let r9 = value.replace(RequestList(requests: [], seq: 44), asked: "e1")
    #expect(r9)
    let bash = try fixture("RemoteRequest.bash", as: RemoteRequest.self)
    let r10 = value.receive(seq: 42, .requestAdd(bash))
    #expect(r10 == .reflected)
    #expect(value.state.seq == 42 && value.open.isEmpty)
    let r11 = value.receive(seq: 43, .sessionRemove(id: "none", replacedBy: nil))
    #expect(r11 == .applied([]))
    let r12 = value.receive(seq: 44, .requestAdd(bash))
    #expect(r12 == .reflected)
    let r13 = value.receive(seq: 45, .requestAdd(bash))
    #expect(r13 == .applied([]))
    #expect(value.open[bash.id] != nil)
}

@Test func anUndecodableFrameTakesItsPlaceOnlyWhenItIsTheNextOne() throws {
    var value = try reconciler()
    let r14 = value.undecodable(seq: 41)
    let r15 = value.undecodable(seq: 43)
    #expect(!r14 && !r15)
    #expect(value.state.seq == 41)
    let r16 = value.undecodable(seq: 42)
    #expect(r16 && value.state.seq == 42)
    value.awaitingSnapshot = true
    let r17 = value.undecodable(seq: 43)
    #expect(!r17 && value.state.seq == 42)
}

@Test func eventsChangeOnlyTheirOwnPart() throws {
    var value = try reconciler()
    let session = try #require(value.state.sessions.values.first)
    #expect(value.apply(.sessionRemove(id: session.id, replacedBy: nil)).isEmpty && value.state.sessions[session.id] == nil)
    _ = value.apply(.sessionUpsert(session))
    #expect(value.state.sessions[session.id] == session)

    _ = value.apply(.hostedAttention(HostedAttention(name: "sa-app-3f9c", kind: .trust, text: "Trust?")))
    #expect(value.state.attention["sa-app-3f9c"] != nil)
    _ = value.apply(.hostedUpsert(try fixture("HostedSession.alive")))
    #expect(value.state.attention["sa-app-3f9c"] == nil, "a changed session's notice is over")

    let finished = try #require(value.state.finished.keys.first)
    _ = value.apply(.finishedResolve(sessionID: finished, reason: ServerEvent.finishedQueueDropped))
    _ = value.apply(.finishedResolve(sessionID: "other", reason: "replied"))
    #expect(value.state.finished.isEmpty && value.state.queueDrops == [finished: 1])

    let account = try #require(value.state.accounts.keys.first)
    _ = value.apply(.accountRemove(id: account))
    #expect(value.state.accounts.isEmpty)
    _ = value.apply(.unknown(type: "something.new"))
    #expect(value.state.seq == 41, "applying an event never moves seq; receive does")
}

@Test func aResolutionMovesTheRequestAndSettlesAnAnswerQueuedForIt() throws {
    var value = try reconciler()
    let queued = Outbox.Item.answer(rid, .deny(message: nil), macID: "mac1", now: 1)
    let other = Outbox.Item.reply("s", RemoteReply(text: "x"), id: "r", macID: "mac1", now: 1)
    value.state.pending = [queued, other]
    let effects = value.apply(.requestResolve(resolution))
    #expect(effects == [.settle(queued, resolution)])
    #expect(value.open[rid] == nil && value.state.resolved[rid] == resolution && value.state.pending == [other])
}

@Test func anAnswerFromThisDeviceIsLeftForItsResponseToSettle() throws {
    var value = try reconciler()
    let queued = Outbox.Item.answer(rid, .deny(message: nil), macID: "mac1", now: 1)
    value.state.pending = [queued]
    let own = RequestResolution(requestID: rid, by: .device, at: 5)
    #expect(value.apply(.requestResolve(own)).isEmpty)
    #expect(value.state.pending == [queued] && value.state.resolved[rid] == own && value.open[rid] == nil)
}

@Test func onlyTheLastFiftyResolutionsAreKept() throws {
    var value = Reconciler()
    for index in 0..<60 { _ = value.apply(.requestResolve(RequestResolution(requestID: "r\(index)", by: .mac, at: Double(index)))) }
    #expect(value.state.resolved.count == 50 && value.state.resolved["r9"] == nil && value.state.resolved["r10"] != nil)
}

@Test func aRestSnapshotIsTakenUnlessTheStreamIsFurtherAlongInTheSameEpoch() throws {
    var value = try reconciler()
    let r18 = value.refreshed(StateSnapshot(seq: 40, epoch: "e1"))
    #expect(!r18 && value.state.seq == 41)
    let r19 = value.refreshed(StateSnapshot(seq: 41, epoch: "e1"))
    #expect(r19 && value.state.sessions.isEmpty)
    let r20 = value.refreshed(StateSnapshot(seq: 3, epoch: "e2"))
    #expect(r20 && value.state.seq == 3 && value.state.epoch == "e2")
}

@Test func aListReplacesItsSliceOnlyWhenNewerThanSeqAndItsLastRefresh() throws {
    var value = try reconciler()
    let r21 = value.replace(RequestList(requests: [], seq: 41), asked: "e1")
    #expect(!r21, "not newer than seq")
    #expect(value.open.count == 1 && value.state.sliceSeq.isEmpty)
    let r22 = value.replace(RequestList(requests: [], seq: 44), asked: "e1")
    #expect(r22)
    #expect(value.open.isEmpty && value.state.sliceSeq[.requests] == 44 && value.state.seq == 41)
    let r23 = value.replace(RequestList(requests: [], seq: 43), asked: "e1")
    #expect(!r23, "older than the slice's last refresh")

    let r26 = value.replace(AccountList(accounts: [], seq: 47), asked: "e1")
    #expect(r26 && value.state.accounts.isEmpty)
    #expect(value.state.sliceSeq == [.requests: 44, .accounts: 47])
}

@Test func aListAskedForUnderAnotherEpochIsLeftOut() throws {
    var value = try reconciler(seq: 2, epoch: "e2")
    let r28 = value.replace(RequestList(requests: [], seq: 60), asked: "e1")
    #expect(!r28)
    let r30 = value.replace(AccountList(accounts: [], seq: 60), asked: "e1")
    #expect(!r30)
    #expect(value.open.count == 1 && value.state.accounts.count == 1 && value.state.sliceSeq.isEmpty)
    let r31 = value.replace(RequestList(requests: [], seq: 60), asked: nil)
    #expect(r31)
}

@Test func requestsWithAnAnswerPendingAreHiddenUntilItSettles() throws {
    var value = try reconciler()
    value.project()
    #expect(value.state.requests[rid] != nil)
    value.state.pending = [Outbox.Item.answer(rid, .deny(message: nil), macID: "mac1", now: 1)]
    value.project()
    #expect(value.state.requests.isEmpty && value.open[rid] != nil)
    value.state.pending = []
    value.project()
    #expect(value.state.requests[rid] != nil)
    value.closed(rid)
    value.project()
    #expect(value.state.requests.isEmpty)
}

private func answerItem(for request: String) -> Outbox.Item {
    Outbox.Item(macID: "mac1", path: "/v1/requests/\(request)/answer", createdAt: 1, expiresAt: 99)
}

@Test func aRowWhoseOnlyRequestIsBeingAnsweredStopsWaitingOnIt() throws {
    var value = try reconciler()
    var session = try #require(value.state.sessions.values.first)
    session.status = .waiting
    session.openRequests = [rid]
    _ = value.apply(.sessionUpsert(session))
    #expect(value.state.sessions[session.id]?.openRequests == [rid] && value.state.sessions[session.id]?.status == .waiting)

    value.state.pending = [answerItem(for: rid)]
    value.project()
    #expect(value.state.requests[rid] == nil)
    #expect(value.state.sessions[session.id]?.openRequests.isEmpty == true && value.state.sessions[session.id]?.status == .working)

    _ = value.apply(.sessionUpsert(session))
    #expect(value.state.sessions[session.id]?.openRequests.isEmpty == true && value.state.sessions[session.id]?.status == .working)

    value.state.pending = []
    value.project()
    #expect(value.state.requests[rid] != nil)
    #expect(value.state.sessions[session.id]?.openRequests == [rid] && value.state.sessions[session.id]?.status == .waiting)
}

@Test func aRowWithAnotherRequestOpenKeepsWaiting() throws {
    var value = try reconciler()
    var session = try #require(value.state.sessions.values.first)
    session.status = .waiting
    session.openRequests = [rid, "other"]
    _ = value.apply(.sessionUpsert(session))
    value.state.pending = [answerItem(for: rid)]
    value.project()
    #expect(value.state.sessions[session.id]?.openRequests == ["other"] && value.state.sessions[session.id]?.status == .waiting)
}
