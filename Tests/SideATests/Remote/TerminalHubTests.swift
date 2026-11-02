import CryptoKit
import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import SideARemoteKit
import Testing

/// What a phone's terminal view saw, read off the socket in the background.
private actor Screen {
    var output = Data()
    var controls: [TermControl] = []
    var closed: SocketClosed?

    func add(_ message: SocketMessage) {
        switch message {
        case .data(let data): if case .output(let bytes)? = TermFrame(data) { output += bytes }
        case .text(let text): if let control = try? JSONDecoder().decode(TermControl.self, from: Data(text.utf8)) { controls.append(control) }
        }
    }

    func end(_ error: Error) { closed = error as? SocketClosed ?? SocketClosed(code: -1) }
    var text: String { String(decoding: output, as: UTF8.self) }
    var acked: UInt32 { controls.compactMap { if case .ack(let seq, nil) = $0 { seq } else { nil } }.max() ?? 0 }
}

private struct Viewer {
    let socket: any SocketConnection
    let screen = Screen()

    init(_ socket: any SocketConnection) {
        self.socket = socket
        let screen = screen
        Task {
            do { while true { await screen.add(try await socket.receive()) } } catch { await screen.end(error) }
        }
    }

    func send(_ control: TermControl) async throws {
        try await socket.send(.text(String(decoding: try JSONEncoder().encode(control), as: UTF8.self)))
    }

    func type(_ seq: UInt32, _ text: String) async throws { try await socket.send(.data(TermFrame.input(seq: seq, bytes: Data(text.utf8)).data)) }
}

@MainActor
private func eventually(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

/// The whole terminal path against real tmux: the phone's URLSession, the TLS listener, a tmux client in a PTY, the
/// fake Claude in the pane.
@MainActor
@Test(.enabled(if: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }))
func aPhoneTerminalTypesOnceSizesTheWindowAndHearsTheEnd() async throws {
    let fixture = try HostedFixture()
    let keychain = try TestKeychain()
    let hosted = HostedSessions(root: fixture.root, environment: fixture.environment, bridge: fixture.bridge)
    await hosted.install()
    let server = RemoteServer(identity: try #require(try keychain.store.identity()), epoch: "e1") { _, _ in HTTPResponse(status: 404) }
    let terminals = TerminalHub(queue: server.queue, epoch: "e1") { hosted }
    hosted.onEnded = { name, status, reason in terminals.ended(name, status: status, reason: reason) }
    hosted.onRefresh = { terminals.queue.async { terminals.evaluateAll() } }
    server.opened = { peer in
        if peer.path.count == 4 { terminals.attach(peer, name: peer.path[3]) } else { peer.close(4404, "") }
    }
    let token = DeviceToken.make()
    let faceID = P256.Signing.PrivateKey()
    server.macID = "mac"
    server.setDevices([(id: "d1", hash: DeviceToken.hash(token))],
                      keys: ["d1": .init(confirm: faceID.publicKey.x963Representation.base64URL, unlock: nil)])
    let port = freePort()
    server.serve(addresses: ["127.0.0.1"], port: port)
    defer { server.stop() }
    do {
        try #require(hosted.available)
        let name = try await hosted.start(.init(agent: .claude, cwd: fixture.project.path, mode: .new(model: nil)))
        let transport = URLSessionTransport(trust: PinnedTrust(.pinned(try #require(try keychain.store.identity()).spkiHash.base64URL)))
        var seconds = 0
        func open(_ path: String, signed: Bool = true) throws -> Viewer {
            var request = URLRequest(url: URL(string: "wss://127.0.0.1:\(port)/v1/ws/term/\(path)")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if signed {
                seconds += 1
                let now = Int(Date().timeIntervalSince1970) + seconds
                let text = try ConfirmMessage.text(macID: "mac", deviceID: "d1", purpose: .terminal, subject: ConfirmMessage.subject(terminal: path), at: now)
                let signature = ConfirmSignature(at: now, signer: .confirm, signature: try faceID.signature(for: Data(text.utf8)).derRepresentation)
                request.setValue(signature.headerValue, forHTTPHeaderField: ConfirmSignature.header)
            }
            return Viewer(transport.socket(request))
        }
        for _ in 0..<250 where server.listenerStates.values.first != .ready { try await Task.sleep(for: .milliseconds(20)) }

        // A terminal is a shell: without Face ID's signature the upgrade is refused.
        let unsigned = try open(name, signed: false)
        try? await unsigned.send(.hello(viewer: UUID().uuidString, cols: 60, rows: 20))
        #expect(await eventually { await unsigned.screen.closed != nil })
        #expect(await unsigned.screen.output.isEmpty)

        let nobody = try open("sa-nothing-here")
        try? await nobody.send(.hello(viewer: UUID().uuidString, cols: 60, rows: 20))
        #expect(await eventually { await nobody.screen.closed?.code == 4404 })

        let id = UUID().uuidString
        let phone = try open(name)
        try await phone.send(.hello(viewer: id, cols: 60, rows: 20))
        #expect(await eventually { await phone.screen.controls.first == .ready(epoch: "e1", applied: nil, cols: 60, rows: 20, owner: "phone") })
        #expect(await eventually { await phone.screen.text.contains("Try \"refactor") })
        // No Mac tab: the phone's size is the window's.
        #expect(await eventually {
            await hosted.command(["display-message", "-p", "-t", "=\(name):", "#{window_width}x#{window_height}"]).output.hasPrefix("60x20")
        })
        // tmux's questions to a new client were answered on the Mac and never reached the phone.
        for query in ["\u{1B}[>q", "\u{1B}[c", "\u{1B}[>c", "\u{1B}]10;?"] { #expect(!(await phone.screen.text.contains(query))) }

        // The fake ignores the first Enter after its composer appears.
        try await phone.type(1, "hi")
        try await phone.type(2, "\r")
        try await phone.type(3, "\r")
        try await phone.type(3, "\r")
        #expect(await eventually { await phone.screen.acked == 3 })
        #expect(await eventually { fixture.lines() == ["'hi'"] })
        try await phone.send(.resize(cols: 70, rows: 22))
        #expect(await eventually { await phone.screen.controls.contains(.size(cols: 70, rows: 22, owner: "phone")) })

        // A missing frame closes the socket; the same viewer reconnecting learns what landed.
        try await phone.type(5, "x")
        #expect(await eventually { await phone.screen.closed?.code == 4422 })
        let again = try open(name)
        try await again.send(.hello(viewer: id, cols: 70, rows: 22))
        #expect(await eventually { await again.screen.controls.first == .ready(epoch: "e1", applied: 3, cols: 70, rows: 22, owner: "phone") })
        let big = Data(repeating: 0x61, count: TermFrame.maxInput + 1)
        try await again.socket.send(.data(TermFrame.input(seq: 4, bytes: big).data))
        #expect(await eventually { await again.screen.controls.contains(.ack(seq: 4, error: "too_large")) })

        try await again.type(5, "/exit")
        try await again.type(6, "\r")
        #expect(await eventually(15) { await again.screen.closed?.code == 4410 })
        #expect(await again.screen.controls.contains(.exit(status: 0, reason: .ended)))

        // Ended from the phone's list: the viewer hears it was killed.
        let second = try await hosted.start(.init(agent: .claude, cwd: fixture.project.path, mode: .new(model: nil)))
        let watching = try open(second)
        try await watching.send(.hello(viewer: UUID().uuidString, cols: 60, rows: 20))
        #expect(await eventually { await watching.screen.text.contains("Try \"refactor") })
        try await hosted.end(second)
        #expect(await eventually(15) { await watching.screen.closed?.code == 4410 })
        let heard = await watching.screen.controls
        #expect(heard.contains { if case .exit(_, .killed) = $0 { true } else { false } }, "\(heard)")
    } catch {
        Issue.record(error)
    }
    await fixture.cleanUp()
}
