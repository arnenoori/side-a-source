#if canImport(Network)
import Foundation
import Network
@testable import SideAProtocol
import Testing

final class Rig: @unchecked Sendable {
    let queue = DispatchQueue(label: "tunnel.rig")
    var phone: TunnelMux!
    var mac: TunnelMux!
    let front: NWListener
    let target: NWListener
    var next: UInt32 = 1
    var frames = 0
    var macEnded: [UInt32] = []
    private let listening = AsyncStream<Void>.makeStream()

    init(tuning: TunnelMux.Tuning = TunnelMux.Tuning(), echo: Bool = true) throws {
        front = try NWListener(using: .tcp, on: .any)
        target = try NWListener(using: .tcp, on: .any)
        // Weak: both listeners and a mux's frames can still fire after a test lets go of its rig.
        phone = TunnelMux(queue: queue, tuning: tuning) { [weak self] frame in
            guard let self else { return }
            frames += 1
            let wire = frame.encoded
            queue.async { self.toMac(TunnelFrame(wire)!) }
        }
        mac = TunnelMux(queue: queue, tuning: tuning) { [weak self] frame in
            guard let self else { return }
            frames += 1
            let wire = frame.encoded
            queue.async { self.phone.received(TunnelFrame(wire)!) }
        }
        mac.ended = { [weak self] id in self?.macEnded.append(id) }
        front.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            let id = next; next += 1
            toMac(TunnelFrame(.open, id))
            phone.attach(id, connection)
        }
        target.newConnectionHandler = { connection in
            connection.start(queue: .global())
            if echo { Self.echo(connection) }
        }
        for listener in [front, target] {
            listener.stateUpdateHandler = { [listening] state in
                switch state {
                case .ready: listening.continuation.yield()
                case .failed, .cancelled: listening.continuation.finish()
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func toMac(_ frame: TunnelFrame) {
        guard frame.kind == .open else { return mac.received(frame) }
        let port = target.port!
        mac.attach(frame.stream, NWConnection(host: "127.0.0.1", port: port, using: .tcp))
    }

    static func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            if let data, !data.isEmpty { connection.send(content: data, completion: .contentProcessed { _ in }) }
            if complete || error != nil {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in DispatchQueue.global().asyncAfter(deadline: .now() + 1) { connection.cancel() } })
                return
            }
            echo(connection)
        }
    }

    func ready() async throws -> NWEndpoint.Port {
        // A listener names port 0 until it is ready.
        var up = 0
        for await _ in listening.stream {
            up += 1
            if up == 2 { break }
        }
        guard up == 2, let port = front.port else { throw CancellationError() }
        return port
    }

    func roundTrip(_ bytes: Data) async throws -> Data {
        let port = try await ready()
        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        client.start(queue: .global())
        client.send(content: bytes, completion: .contentProcessed { _ in })
        return await withCheckedContinuation { done in
            let received = Received()
            func read() {
                client.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                    if let data { received.data.append(data) }
                    if complete || error != nil || received.data.count >= bytes.count { client.cancel(); done.resume(returning: received.data); return }
                    read()
                }
            }
            read()
        }
    }

    final class Received: @unchecked Sendable { var data = Data() }

    deinit { front.cancel(); target.cancel() }
}

@Test func streamsCarryBytesBothWaysAndEnd() async throws {
    let rig = try Rig()
    let bytes = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let back = try await rig.roundTrip(bytes)
    #expect(back == bytes)
    try await Task.sleep(for: .milliseconds(50))
    rig.queue.sync {
        #expect(rig.phone.count == 0)
        #expect(rig.mac.count == 0)
    }
}

@Test func aSmallWindowStillMovesEverything() async throws {
    var tuning = TunnelMux.Tuning()
    tuning.window = 8 << 10
    tuning.creditBatch = 2 << 10
    let rig = try Rig(tuning: tuning)
    let bytes = Data((0..<400_000).map { UInt8(truncatingIfNeeded: $0) })
    #expect(try await rig.roundTrip(bytes) == bytes)
}

@Test func smallWritesCloseTogetherGoAsOneFrame() async throws {
    let rig = try Rig()
    let port = try await rig.ready()
    let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    client.start(queue: .global())
    for _ in 0..<1500 where client.state != .ready { try await Task.sleep(for: .milliseconds(20)) }
    let before = rig.queue.sync { rig.frames }
    for byte in 0..<40 { client.send(content: Data([UInt8(byte)]), completion: .contentProcessed { _ in }) }
    // swiftlint:disable:next sleep_literal_in_tests -- the check is an upper bound on frames, so the 16 ms coalescing window and the echo must have had time to happen
    try await Task.sleep(for: .milliseconds(150))
    let data = rig.queue.sync { rig.frames } - before
    client.cancel()
    #expect(data < 20)
}

@Test func aResetEndsBothSides() async throws {
    let rig = try Rig(echo: false)
    let port = try await rig.ready()
    let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    client.start(queue: .global())
    client.send(content: Data("hi".utf8), completion: .contentProcessed { _ in })
    for _ in 0..<100 where rig.queue.sync(execute: { rig.mac.count }) == 0 { try await Task.sleep(for: .milliseconds(5)) }
    let id = try #require(rig.queue.sync { rig.mac.ids.first })
    rig.queue.sync { rig.phone.reset(id, "test") }
    for _ in 0..<100 where rig.queue.sync(execute: { rig.mac.count }) > 0 { try await Task.sleep(for: .milliseconds(5)) }
    rig.queue.sync {
        #expect(rig.mac.count == 0)
        #expect(rig.macEnded == [id])
    }
    client.cancel()
}

@Test func dataPastTheCreditWindowResetsTheStream() async throws {
    let queue = DispatchQueue(label: "tunnel.credit")
    var tuning = TunnelMux.Tuning()
    tuning.window = 64 << 10
    let sent = Box<[TunnelFrame]>([])
    let mux = TunnelMux(queue: queue, tuning: tuning) { frame in sent.value.append(frame) }
    let target = try NWListener(using: .tcp, on: .any)
    target.newConnectionHandler = { $0.start(queue: .global()) }
    target.start(queue: queue)
    for _ in 0..<200 where (target.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(5)) }
    let chunk = Data(count: 32 << 10)
    queue.sync {
        mux.attach(7, NWConnection(host: "127.0.0.1", port: target.port!, using: .tcp))
        for _ in 0..<3 { mux.received(TunnelFrame(.data, 7, chunk)) }
    }
    let frames = queue.sync { sent.value }
    #expect(frames.contains { $0.kind == .reset && $0.stream == 7 && $0.reason == "over credit" })
    #expect(queue.sync { mux.count } == 0)
    target.cancel()
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Test func aFinIsAnsweredWithAFinAndALateOneWithNothing() async throws {
    let queue = DispatchQueue(label: "tunnel.fin")
    let sent = Box<[TunnelFrame]>([])
    let mux = TunnelMux(queue: queue) { frame in sent.value.append(frame) }
    let target = try NWListener(using: .tcp, on: .any)
    target.newConnectionHandler = { $0.start(queue: .global()) }
    target.start(queue: queue)
    for _ in 0..<200 where (target.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(5)) }
    queue.sync {
        mux.attach(5, NWConnection(host: "127.0.0.1", port: target.port!, using: .tcp))
        mux.received(TunnelFrame(.fin, 5))
        mux.received(TunnelFrame(.fin, 9))
    }
    let frames = queue.sync { sent.value }
    #expect(frames == [TunnelFrame(.fin, 5)])
    target.cancel()
}

@Test func aRigItsTestLetGoOfIgnoresWhatStillArrives() throws {
    var rig: Rig? = try Rig()
    weak let gone = rig
    let ended = try #require(rig?.mac.ended)
    rig = nil
    #expect(gone == nil)
    ended(1)
}
#endif
