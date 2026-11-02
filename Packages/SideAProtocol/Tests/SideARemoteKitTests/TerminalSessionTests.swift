import Foundation
@testable import SideARemoteKit
import SideAProtocol
import Testing

private func inputs(_ socket: FakeSocket) -> [TermFrame] {
    socket.raw.compactMap { if case .data(let data) = $0 { TermFrame(data) } else { nil } }
}

private func terminal(_ mac: FakeMac, _ outbox: Outbox) -> TerminalSession {
    TerminalSession(client: RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_token"), transport: mac), name: "sa-app-3f9c",
                    viewer: "viewer-1", outbox: outbox)
}

@Test func inputIsNumberedAckedAndResentAfterAReconnect() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    let term = terminal(mac, outbox)
    try await term.open(cols: 80, rows: 24)
    let first = try await mac.socket(0)
    #expect(first.request.url?.path == "/v1/ws/term/sa-app-3f9c")
    #expect(!(await term.input(Data("too early".utf8))))
    first.push(.ready(epoch: "e1", applied: nil, cols: 80, rows: 24, owner: "phone"))
    try await until("ready") { await term.input(Data("ls\r".utf8)) }
    #expect(await term.input(Data("pwd\r".utf8)))
    try await until("sent") { inputs(first).count == 2 }
    #expect(inputs(first) == [.input(seq: 1, bytes: Data("ls\r".utf8)), .input(seq: 2, bytes: Data("pwd\r".utf8))])
    first.push(.ack(seq: 1, error: nil))
    try await until("acked") { await outbox.terminalInput(viewer: "viewer-1").map(\.seq) == [2] }

    // Same epoch: the Mac applied 1, so only 2 goes again, and new keys continue at 3.
    try await term.open(cols: 80, rows: 24)
    let second = try await mac.socket(1)
    second.push(.ready(epoch: "e1", applied: 1, cols: 80, rows: 24, owner: "phone"))
    try await until("resent") { inputs(second) == [.input(seq: 2, bytes: Data("pwd\r".utf8))] }
    #expect(await term.input(Data("q".utf8)))
    try await until("next") { inputs(second).last == .input(seq: 3, bytes: Data("q".utf8)) }
    await term.close()
}

@Test func anotherEpochDiscardsUnackedKeysWithANotice() async throws {
    let mac = FakeMac()
    let (outbox, file) = try temporaryOutbox()
    let term = terminal(mac, outbox)
    try await term.open(cols: 80, rows: 24)
    let first = try await mac.socket(0)
    first.push(.ready(epoch: "e1", applied: nil, cols: 80, rows: 24, owner: "phone"))
    try await until("ready") { await term.input(Data("rm -rf build\r".utf8)) }
    await term.close()

    // A new process (the app relaunched) finds the unacked frame in the shared store; Side A restarted meanwhile.
    let again = terminal(mac, try Outbox(file: file))
    var events = again.events.makeAsyncIterator()
    try await again.open(cols: 80, rows: 24)
    let second = try await mac.socket(1)
    second.push(.ready(epoch: "e2", applied: 1, cols: 100, rows: 30, owner: "mac"))
    #expect(await events.next() == .notice(TerminalSession.restartNotice))
    #expect(await events.next() == .size(cols: 100, rows: 30, owner: "mac"))
    try await Task.sleep(for: .milliseconds(30))
    #expect(inputs(second).isEmpty)
    #expect(await outbox.terminalInput(viewer: "viewer-1").isEmpty)
    // Seq starts again at 1.
    #expect(await again.input(Data("y".utf8)))
    try await until("restarted") { inputs(second) == [.input(seq: 1, bytes: Data("y".utf8))] }

    second.push(frame: .output(Data("hi".utf8)))
    #expect(await events.next() == .output(Data("hi".utf8)))
    second.push(.exit(status: nil, reason: .killed))
    #expect(await events.next() == .exit(status: nil, reason: .killed))
    await again.close()
}

/// After a reconnect, keys wait for the new `ready`: none go out under the old epoch, and nothing is
/// replayed except what `ready` says the Mac didn't apply. A frame the Mac only partly wrote comes back as
/// `applied: nil`, so it is dropped, never sent twice.
@Test func aReconnectTakesNoKeysUntilReadyAndNeverReplaysAPartlyWrittenFrame() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    let term = terminal(mac, outbox)
    try await term.open(cols: 80, rows: 24)
    let first = try await mac.socket(0)
    first.push(.ready(epoch: "e1", applied: nil, cols: 80, rows: 24, owner: "phone"))
    try await until("ready") { await term.input(Data("make deploy\r".utf8)) }
    try await until("sent") { inputs(first).count == 1 }

    try await term.open(cols: 80, rows: 24)
    let second = try await mac.socket(1)
    #expect(!(await term.input(Data("x".utf8))))
    second.push(.ready(epoch: "e1", applied: nil, cols: 80, rows: 24, owner: "phone"))
    try await until("notice") {
        var seen = false
        for await event in term.events { if case .notice(TerminalSession.restartNotice) = event { seen = true; break } }
        return seen
    }
    #expect(inputs(second).isEmpty)
    #expect(await outbox.terminalInput(viewer: "viewer-1").isEmpty)
    #expect(await term.input(Data("y".utf8)))
    try await until("fresh seq") { inputs(second) == [.input(seq: 1, bytes: Data("y".utf8))] }
    await term.close()
}
