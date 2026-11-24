import Foundation
@testable import SideARemoteKit
import SideAProtocol
import Testing

private func session(_ mac: FakeMac, confirm: @escaping @Sendable (ScreenMode) async -> String?) -> ScreenSession {
    ScreenSession(client: RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_token"), transport: mac), confirm: confirm)
}

@Test func openSendsHelloOnTheModeSocketWithTheConfirmHeader() async throws {
    let mac = FakeMac()
    let screen = session(mac) { _ in "signed" }
    try await screen.open(.control, hello: ScreenHello(maxWidth: 100, maxHeight: 200))
    let socket = try await mac.socket(0)
    #expect(socket.request.url?.path == "/v1/ws/screen/control")
    #expect(socket.request.value(forHTTPHeaderField: ConfirmSignature.header) == "signed")
    await screen.close()
}

@Test func noSignatureIsNoSocket() async throws {
    let mac = FakeMac()
    let screen = session(mac) { _ in nil }
    await #expect(throws: ScreenSession.Unsigned.self) { try await screen.open(.view, hello: ScreenHello(maxWidth: 1, maxHeight: 1)) }
    #expect(mac.sockets.isEmpty)
}

/// Face ID takes seconds, and the phone can ask again meanwhile (Try Again, Control): only the newest open may keep a
/// socket, since the Mac replaces the older viewer and the phone would be left reading a socket that is already closed.
@Test func anOpenThatWakesAfterANewerOneDropsOut() async throws {
    let mac = FakeMac()
    let first = Gate(), second = Gate()
    let calls = Counter()
    let screen = session(mac) { _ in
        let mine = calls.next()
        await (mine == 1 ? first : second).wait()
        return "signed\(mine)"
    }
    let hello = ScreenHello(maxWidth: 1, maxHeight: 1)
    let older = Task { try await screen.open(.view, hello: hello) }
    try await until("first asks") { first.arrived == 1 }
    let newer = Task { try await screen.open(.control, hello: hello) }
    try await until("second asks") { second.arrived == 1 }
    first.open()
    try await older.value
    #expect(mac.sockets.isEmpty)
    second.open()
    try await newer.value
    let socket = try await mac.socket(0)
    #expect(mac.sockets.count == 1)
    #expect(socket.request.url?.path == "/v1/ws/screen/control")
    await screen.close()
}

@Test func closingWhileSigningLeavesNoSocket() async throws {
    let mac = FakeMac()
    let gate = Gate()
    let screen = session(mac) { _ in
        await gate.wait()
        return "signed"
    }
    let opening = Task { try await screen.open(.view, hello: ScreenHello(maxWidth: 1, maxHeight: 1)) }
    try await until("asks") { gate.arrived == 1 }
    await screen.close()
    gate.open()
    try await opening.value
    #expect(mac.sockets.isEmpty)
}

@Test func aRefusalThenTheCloseCodeReachTheEvents() async throws {
    let mac = FakeMac()
    let screen = session(mac) { _ in "signed" }
    var events = screen.events.makeAsyncIterator()
    try await screen.open(.view, hello: ScreenHello(maxWidth: 1, maxHeight: 1))
    let socket = try await mac.socket(0)
    socket.push(raw: #"{"type":"refused","data":{"reason":"permission","message":"Allow Side A"}}"#)
    socket.serverClose(ScreenRefusal.permission.closeCode)
    guard case .control(.refused(let refused))? = await events.next() else {
        Issue.record("no refusal")
        return
    }
    #expect(refused == ScreenRefused(reason: .permission, message: "Allow Side A"))
    guard case .closed(let code)? = await events.next() else {
        Issue.record("no close")
        return
    }
    #expect(code == 4412)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// Screen off or no permission: the Mac sends why and closes before the phone's hello can go out. That is a refusal to show,
/// not a Mac that can't be reached.
@Test func aMacThatRefusesBeforeTheHelloStillGivesItsReason() async throws {
    let mac = FakeMac()
    mac.onSocket = { socket in
        socket.failSends(SocketClosed(code: ScreenRefusal.off.closeCode, reason: "off"))
        socket.push(raw: #"{"type":"refused","data":{"reason":"off","message":"Screen is off on the Mac."}}"#)
        socket.serverClose(ScreenRefusal.off.closeCode)
    }
    let screen = session(mac) { _ in "signed" }
    var events = screen.events.makeAsyncIterator()
    try await screen.open(.view, hello: ScreenHello(maxWidth: 1, maxHeight: 1))
    guard case .control(.refused(let refused))? = await events.next() else {
        Issue.record("no refusal")
        return
    }
    #expect(refused.reason == .off)
    guard case .closed(let code)? = await events.next() else {
        Issue.record("no close")
        return
    }
    #expect(ScreenClose(code: code) == .refused(.off))
}
