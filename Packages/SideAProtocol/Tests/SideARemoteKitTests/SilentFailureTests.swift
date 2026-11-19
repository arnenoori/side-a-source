import Foundation
@testable import SideARemoteKit
import SideAProtocol
import Testing

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    func has(_ text: String) -> Bool { lock.withLock { lines.contains { $0.contains(text) } } }
}

/// The log sink is global, so these two run one after the other.
@Suite(.serialized) struct SilentFailureTests {
    private func listen() -> Lines {
        let lines = Lines()
        KitLog.sink = { _, line in lines.add(line) }
        return lines
    }

    @Test func aMessageTheSocketRefusesIsLogged() async throws {
        let lines = listen()
        defer { KitLog.sink = nil }
        let mac = FakeMac()
        let sync = try engine(mac)
        await sync.start()
        let socket = try await mac.socket(0)
        socket.push(nil, welcome("e", seq: 0, replay: false))
        try await until("live") { await sync.state.connection.isLive }
        socket.failSends(URLError(.networkConnectionLost))
        await sync.setForeground(true)
        try await until("logged") { lines.has("send failed") }
        await sync.stop()
    }

    @Test func aRefreshThatFailsAfterAnUndecodableEventIsLogged() async throws {
        let lines = listen()
        defer { KitLog.sink = nil }
        let mac = FakeMac()
        let sync = try engine(mac)
        await sync.start()
        let socket = try await mac.socket(0)
        try socket.push(fixture: "ServerEvent.welcome")
        try socket.push(fixture: "ServerEvent.snapshot")
        try await until("snapshot") { await sync.state.seq == 41 }
        mac.respond { _ in .init(status: 0) }
        var frame = try #require(JSONSerialization.jsonObject(with: json(EventEnvelope(seq: 42, at: 1, event: .hostedRemove(name: "x")))) as? [String: Any])
        frame["data"] = ["name": 7]
        socket.push(raw: String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self))
        try await until("logged") { lines.has("refresh after event 42 failed") }
        await sync.stop()
    }
}
