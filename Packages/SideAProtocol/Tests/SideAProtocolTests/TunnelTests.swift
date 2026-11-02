import Foundation
import Network
@testable import SideAProtocol
import Testing

@Test func framesKeepTheirByteLayout() throws {
    let frame = TunnelFrame(.data, 0x0001_0007, Data([1, 2, 3]))
    #expect(frame.encoded == Data([2, 0, 1, 0, 7, 1, 2, 3]))
    #expect(TunnelFrame(frame.encoded) == frame)
    #expect(TunnelFrame.credit(9, 262_144).granted == 262_144)
    #expect(TunnelFrame(Data([9, 0, 0, 0, 1])) == nil)
    #expect(TunnelFrame(Data([2, 0, 0])) == nil)
    #expect(TunnelFrame(Data([2, 0, 0, 0, 1]) + Data(count: TunnelFrame.maxPayload + 1)) == nil)
    #expect(TunnelControl(text: #"{"type":"mac","online":false}"#)?.online == false)
    #expect(TunnelControl(type: "pairing").text == #"{"type":"pairing"}"#)
}

/// Two muxes joined in memory, the way the relay joins them: the phone's end takes connections from a front listener,
/// the Mac's end opens one to a target per OPEN.
final class Rig: @unchecked Sendable {
    let queue = DispatchQueue(label: "tunnel.rig")
    var phone: TunnelMux!
    var mac: TunnelMux!
    let front: NWListener
    let target: NWListener
    var next: UInt32 = 1
    var frames = 0
    var macEnded: [UInt32] = []

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
        for listener in [front, target] { listener.start(queue: queue) }
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
        for _ in 0..<200 {
            if let port = front.port, port.rawValue != 0, (target.port?.rawValue ?? 0) != 0 { return port }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CancellationError()
    }

    /// Connects to the front, sends `bytes`, reads as many back, and closes, as URLSession would.
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
    try await Task.sleep(for: .milliseconds(100))
    // A first keystroke goes at once; the burst behind it within 16 ms is coalesced.
    let before = rig.queue.sync { rig.frames }
    for byte in 0..<40 { client.send(content: Data([UInt8(byte)]), completion: .contentProcessed { _ in }) }
    try await Task.sleep(for: .milliseconds(150))
    let data = rig.queue.sync { rig.frames } - before
    client.cancel()
    // Out: a handful of DATA frames, not 40; back: the echo's, and credits.
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
        // Two chunks fill the window; the third was never granted.
        for _ in 0..<3 { mux.received(TunnelFrame(.data, 7, chunk)) }
    }
    let frames = queue.sync { sent.value }
    #expect(frames.contains { $0.kind == .reset && $0.stream == 7 && $0.reason == "over credit" })
    #expect(queue.sync { mux.count } == 0)
    target.cancel()
}

@Test func controlTextNeverTraps() {
    let samples = [
        #"{"type":"gone","slot":-1}"#, #"{"type":"gone","slot":1e30}"#, #"{"type":"gone","slot":4294967296}"#,
        #"{"type":"gone","slot":"1"}"#, #"{"type":"devices","devices":[{"id":1}]}"#, #"{"type":null}"#, "[]", "", "{", "pong",
        #"{"type":"mac","online":"yes"}"#, #"{"type":"pairing","expiresAt":"NaN"}"#,
    ]
    var generator = SystemRandomNumberGenerator()
    let random = (0..<500).map { _ in
        String(decoding: (0..<Int.random(in: 0..<64, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }, as: UTF8.self)
    }
    for text in samples + random {
        _ = TunnelControl(text: text)
    }
    #expect(TunnelControl(text: #"{"type":"gone","slot":-1}"#)?.slot == -1)
    #expect(TunnelControl(text: #"{"type":"gone","slot":1e30}"#) == nil)
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
        // The peer's answer to a FIN this side sent, after the stream ended here.
        mux.received(TunnelFrame(.fin, 9))
    }
    let frames = queue.sync { sent.value }
    #expect(frames == [TunnelFrame(.fin, 5)])
    target.cancel()
}

/// A stream's end or a late connection can reach the rig's closures after its test has let go of it.
@Test func aRigItsTestLetGoOfIgnoresWhatStillArrives() throws {
    var rig: Rig? = try Rig()
    weak let gone = rig
    let ended = try #require(rig?.mac.ended)
    rig = nil
    #expect(gone == nil)
    ended(1)
}
