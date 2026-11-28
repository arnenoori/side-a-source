import Foundation
import Testing
@testable import SideADaemonKit

private func begin(_ ledger: IdempotencyLedger) async -> IdempotencyLedger.Lookup {
    await ledger.begin(device: "phone", key: "k1", method: "POST", path: "/v1/sessions", body: Data(), now: 0)
}

@Test func aRepeatIsToldWhenTheFirstCallFinishesAndThenReplaysIt() async {
    let ledger = IdempotencyLedger(store: nil)
    #expect(await begin(ledger) == .run)
    #expect(await begin(ledger) == .running)
    async let finished = ledger.settled(device: "phone", key: "k1", within: .seconds(30))
    await ledger.finish(device: "phone", key: "k1", status: 200, contentType: nil, body: Data("ok".utf8))
    #expect(await finished)
    #expect(await begin(ledger) == .replay(status: 200, contentType: nil, body: Data("ok".utf8)))
}

@Test func aRepeatStopsWaitingForAFirstCallThatOutlastsTheLimit() async {
    let ledger = IdempotencyLedger(store: nil)
    #expect(await begin(ledger) == .run)
    #expect(await ledger.settled(device: "phone", key: "k1", within: .milliseconds(20)) == false)
    #expect(await begin(ledger) == .running)
}

@Test func nothingRunningIsSettledAtOnce() async {
    #expect(await IdempotencyLedger(store: nil).settled(device: "phone", key: "k1", within: .seconds(30)))
}
