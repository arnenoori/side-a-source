import Foundation
@testable import SideACore
import Testing

private let now = 1_800_000_000.0

/// Two computers and the link between them, with any one message dropped.
private struct Pair {
    enum Message: CaseIterable { case stageRequest, stageReply, commitRequest, commitReply, abortRequest, statusReply }

    var source = MoveJournal()
    var destination = MoveJournal()
    var runsHere = true
    var runsThere = false
    var lost: Set<Message> = []
    /// A start request can only arrive late if the source ever sent one.
    var askedToStart = false
    let id = "move-0001"

    private func entry(_ role: MoveJournal.Role, _ step: MoveJournal.Step) -> MoveJournal.Entry {
        MoveJournal.Entry(id: id, role: role, session: "s1", agent: "claude", peer: role == .source ? "mini" : "laptop",
                          peerName: role == .source ? "Mac mini" : "MacBook", step: step, at: now)
    }

    /// The source's side of a move, stopping where a message is lost, as the app would on a timeout.
    mutating func move() {
        source.begin(entry(.source, .prepared))
        source.advance(id, to: .held, at: now)
        runsHere = false
        guard !lost.contains(.stageRequest) else { return }
        guard destination.receive(entry(.destination, .staging)), destination.staged(id, folder: "/landed", name: "sa-app-1a2b", at: now) else { return }
        guard !lost.contains(.stageReply) else { return }
        source.advance(id, to: .sent, at: now)
        source.advance(id, to: .committing, at: now)
        askedToStart = true
        deliverCommit()
        guard !lost.contains(.commitReply), runsThere else { return }
        source.advance(id, to: .away, at: now)
    }

    mutating func deliverCommit() {
        guard askedToStart, !lost.contains(.commitRequest) else { return }
        if destination.commit(id, at: now) == .start { destination.started(id, at: now); runsThere = true }
    }

    /// What the source does when it comes back to a move it did not finish.
    mutating func recover(reachable: Bool) {
        switch source.recovery(id) {
        case .rollBack:
            source.returned(id, at: now)
            runsHere = true
            if reachable, !lost.contains(.abortRequest) { abort() }
        case .ask:
            if source[id]?.step == .committing { source.advance(id, to: .unknown, at: now) }
            guard reachable, !lost.contains(.statusReply) else { return }
            var status = destination.status(id)
            if status == .staged || status == .staging || status == .none { status = abort() }
            if source.settle(id, peerSays: status, at: now) { runsHere = true }
        case .nothing: break
        }
    }

    @discardableResult
    mutating func abort() -> MoveJournal.PeerStatus {
        destination.abort(id, session: "s1", agent: "claude", peer: "laptop", peerName: "MacBook", at: now).status
    }
}

@Test func aMoveWithNothingLostEndsRunningOnlyThere() {
    var pair = Pair()
    pair.move()
    #expect(!pair.runsHere && pair.runsThere)
    #expect(pair.source.ownership(of: "s1") == .away(peer: "mini"))
    #expect(pair.destination.ownership(of: "s1") == .here)
    #expect(pair.source.recovery(pair.id) == .nothing)
}

@Test func whateverMessageIsLostTheConversationNeverRunsOnBothAndIsNeverLost() {
    for lost in Pair.Message.allCases {
        for reachable in [false, true] {
            var pair = Pair()
            pair.lost = [lost]
            pair.move()
            #expect(!(pair.runsHere && pair.runsThere), "\(lost)")
            pair.recover(reachable: reachable)
            #expect(!(pair.runsHere && pair.runsThere), "\(lost) reachable \(reachable)")
            // A request that was only delayed arrives after everything else.
            pair.lost = []
            pair.deliverCommit()
            #expect(!(pair.runsHere && pair.runsThere), "\(lost) reachable \(reachable), late start request")
            // Once the two can talk, exactly one of them has it.
            pair.recover(reachable: true)
            #expect(pair.runsHere != pair.runsThere, "\(lost) reachable \(reachable), settled")
            #expect(pair.source.ownership(of: "s1") == (pair.runsThere ? .away(peer: "mini") : .here))
        }
    }
}

@Test func aLostAnswerToTheStartRequestIsUnknownUntilTheDestinationIsAsked() {
    var pair = Pair()
    pair.lost = [.commitReply]
    pair.move()
    #expect(pair.runsThere)
    pair.recover(reachable: false)
    #expect(pair.source.ownership(of: "s1") == .unknown(peer: "mini"))
    #expect(!pair.source.ownership(of: "s1").mayRun)
    #expect(!pair.runsHere)
    pair.lost = []
    pair.recover(reachable: true)
    #expect(pair.source.ownership(of: "s1") == .away(peer: "mini"))
    #expect(!pair.runsHere)
}

@Test func aStartRequestIsAnsweredOnceAndNeverAfterTheCopyWasDropped() {
    var journal = MoveJournal()
    let entry = MoveJournal.Entry(id: "m1", role: .destination, session: "s1", agent: "codex", peer: "laptop", peerName: "MacBook", step: .staging, at: now)
    do { var copy = journal; let got = copy.commit("m1", at: now); journal = copy; #expect(got == .refused) }
    do { var copy = journal; let got = copy.receive(entry); journal = copy; #expect(got) }
    do { var copy = journal; let got = copy.commit("m1", at: now); journal = copy; #expect(got == .refused) }
    #expect(journal.ownership(of: "s1") == .arriving(peer: "laptop"))
    do { var copy = journal; let got = copy.staged("m1", folder: "/landed", name: "sa-app-1a2b", at: now); journal = copy; #expect(got) }
    do { var copy = journal; let got = copy.commit("m1", at: now); journal = copy; #expect(got == .start) }
    // Asked again while it is starting, it says so; that is neither a start nor a refusal.
    do { var copy = journal; let got = copy.commit("m1", at: now); journal = copy; #expect(got == .starting) }
    #expect(journal.status("m1") == .starting && journal.ownership(of: "s1") == .arriving(peer: "laptop"))
    do { var copy = journal; let got = copy.started("m1", at: now); journal = copy; #expect(got) }
    do { var copy = journal; let got = copy.commit("m1", at: now); journal = copy; #expect(got == .alreadyLive) }
    do { var copy = journal; let got = copy.abort("m1", session: "s1", agent: "codex", peer: "laptop", peerName: "MacBook", at: now); journal = copy; #expect(got == (false, .live)) }
    #expect(journal["m1"]?.folder == "/landed")

    do { var copy = journal; let got = copy.abort("m2", session: "s2", agent: "codex", peer: "laptop", peerName: "MacBook", at: now); journal = copy; #expect(got == (false, .none)) }
    let late = MoveJournal.Entry(id: "m2", role: .destination, session: "s2", agent: "codex", peer: "laptop", peerName: "MacBook", step: .staging, at: now)
    do { var copy = journal; let got = copy.receive(late); journal = copy; #expect(!got) }
    do { var copy = journal; let got = copy.commit("m2", at: now); journal = copy; #expect(got == .refused) }
    #expect(journal.status("m2") == .discarded)
}

@Test func stepsOnlyGoForward() {
    var journal = MoveJournal()
    journal.begin(MoveJournal.Entry(id: "m1", role: .source, session: "s1", agent: "claude", peer: "mini", peerName: "Mac mini", step: .prepared, at: now))
    do { var copy = journal; let got = copy.advance("m1", to: .away, at: now); journal = copy; #expect(!got) }
    do { var copy = journal; let got = copy.advance("m1", to: .committing, at: now); journal = copy; #expect(!got) }
    do { var copy = journal; let got = copy.advance("m1", to: .held, at: now); journal = copy; #expect(got) }
    #expect(journal.ownership(of: "s1") == .leaving(peer: "mini"))
    do { var copy = journal; let got = copy.advance("m1", to: .returned, at: now); journal = copy; #expect(got) }
    do { var copy = journal; let got = copy.advance("m1", to: .sent, at: now); journal = copy; #expect(!got) }
    #expect(journal.ownership(of: "s1") == .here)
    do { var copy = journal; let got = copy.advance("missing", to: .held, at: now); journal = copy; #expect(!got) }
}

@Test func aSessionThatCameBackAndLeftAgainFollowsItsNewestMove() {
    var journal = MoveJournal()
    for (id, at) in [("m1", now), ("m2", now + 100)] {
        journal.begin(MoveJournal.Entry(id: id, role: .source, session: "s1", agent: "claude", peer: "mini", peerName: "Mac mini", step: .prepared, at: at))
        for step in [MoveJournal.Step.held, .sent, .committing, .away] { journal.advance(id, to: step, at: at) }
    }
    journal.returned("m1", at: now + 50)
    #expect(journal.ownership(of: "s1") == .away(peer: "mini"))
    #expect(journal.open(for: "s1")?.id == "m2")
    journal.returned("m2", at: now + 200)
    #expect(journal.ownership(of: "s1") == .here)
    #expect(journal.open(for: "s1") == nil)
}

@Test func aStagedCopyNobodyStartedIsDroppedAndOldEntriesAreForgotten() throws {
    var journal = MoveJournal()
    let entry = MoveJournal.Entry(id: "m1", role: .destination, session: "s1", agent: "claude", peer: "laptop", peerName: "MacBook", step: .staging, at: now)
    do { var copy = journal; let got = copy.receive(entry); journal = copy; #expect(got) }
    do { var copy = journal; let got = copy.staged("m1", folder: "/landed", name: "sa-app-1a2b", at: now); journal = copy; #expect(got) }
    do { var copy = journal; let got = copy.expire(now: now + MoveJournal.stagedFor - 1); journal = copy; #expect(got.isEmpty) }
    do { var copy = journal; let got = copy.expire(now: now + MoveJournal.stagedFor); journal = copy; #expect(got.map(\.id) == ["m1"]) }
    do { var copy = journal; let got = copy.commit("m1", at: now + MoveJournal.stagedFor); journal = copy; #expect(got == .refused) }
    let saved = try JSONDecoder().decode(MoveJournal.self, from: JSONEncoder().encode(journal))
    #expect(saved == journal)
    do { var copy = journal; let got = copy.expire(now: now + MoveJournal.stagedFor + MoveJournal.remembered); journal = copy; #expect(got.isEmpty) }
    #expect(journal["m1"] == nil)
}

@Test func aSessionThatRanAndLeftAgainStillCountsAsStartedToWhoeverSentIt() {
    var journal = MoveJournal()
    let entry = MoveJournal.Entry(id: "m1", role: .destination, session: "s1", agent: "claude", peer: "laptop", peerName: "MacBook", step: .staging, at: now)
    do { var copy = journal; _ = copy.receive(entry); _ = copy.staged("m1", folder: "/landed", name: "sa-app-1a2b", at: now); _ = copy.commit("m1", at: now); _ = copy.started("m1", at: now); journal = copy }
    do { var copy = journal; copy.ended("m1", at: now); journal = copy }
    // The sender, still unsure, asks: it must hear that it started, or it would run the session a second time.
    #expect(journal.status("m1") == .live)
    #expect(journal.ownership(of: "s1") == .here)
    do { var copy = journal; let got = copy.commit("m1", at: now); journal = copy; #expect(got == .alreadyLive) }
    do { var copy = journal; let got = copy.abort("m1", session: "s1", agent: "claude", peer: "laptop", peerName: "MacBook", at: now); journal = copy; #expect(got == (false, .live)) }

    // One that was asked to start and failed is dropped, and says so.
    let second = MoveJournal.Entry(id: "m2", role: .destination, session: "s2", agent: "claude", peer: "laptop", peerName: "MacBook", step: .staging, at: now)
    do { var copy = journal; _ = copy.receive(second); _ = copy.staged("m2", folder: "/landed", name: "sa-app-3c4d", at: now); _ = copy.commit("m2", at: now); copy.failed("m2", at: now); journal = copy }
    #expect(journal.status("m2") == .discarded)

    var source = MoveJournal()
    source.begin(MoveJournal.Entry(id: "m3", role: .source, session: "s3", agent: "claude", peer: "mini", peerName: "Mac mini", step: .prepared, at: now))
    for step in [MoveJournal.Step.held, .sent, .committing] { source.advance("m3", to: step, at: now) }
    let restarts = source.settle("m3", peerSays: .starting, at: now)
    #expect(!restarts)
    #expect(source.ownership(of: "s3") == .unknown(peer: "mini"))
}

@Test func aMoveOfASessionWhoseAgentHadExitedSaysSoAcrossARelaunchAndOldJournalsReadAsBefore() throws {
    var journal = MoveJournal()
    var entry = MoveJournal.Entry(id: "m1", role: .source, session: "s1", agent: "claude", peer: "laptop", peerName: "MacBook", step: .prepared, at: now)
    entry.ended = "m0"
    journal.begin(entry)
    let saved = try JSONDecoder().decode(MoveJournal.self, from: JSONEncoder().encode(journal))
    #expect(saved["m1"]?.ended == "m0")
    // Written before the field existed: every move it holds stopped a running session.
    let old = Data(#"{"entries":{"m2":{"id":"m2","role":"source","session":"s2","agent":"claude","peer":"mini","peerName":"Mac mini","step":"held","startedAt":1,"updatedAt":1}}}"#.utf8)
    let read = try JSONDecoder().decode(MoveJournal.self, from: old)["m2"]
    #expect(read?.step == .held && read?.ended == nil)
}
