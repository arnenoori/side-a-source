import CryptoKit
import Foundation
import Network
import SideACore
import SideAProtocol

/// The relay's tunnel (relay/src/tunnel.ts, docs/remote/tunnel.md) in the test process: one computer's socket and the
/// sockets that reach it, frames passed through unread with the caller's slot in the high half of the stream id, and a
/// caller let in only with a device credential whose secret the computer listed. No signatures, budgets or pairing:
/// what a phone, or another computer, reaching a computer through the relay needs of it.
final class LocalRelay: @unchecked Sendable {
    private final class Socket {
        let connection: NWConnection
        /// 0 for the computer the relay is for; each caller's socket gets its own.
        let slot: Int
        let device: String?
        var buffer = Data()
        var message = Data()
        var opcode: UInt8 = 0
        init(_ connection: NWConnection, slot: Int, device: String?) { self.connection = connection; self.slot = slot; self.device = device }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalRelay")
    private var host: Socket?
    private var callers: [Int: Socket] = [:]
    private var devices: [String: String] = [:]
    private var slots = 0
    private var bytes = 0
    private var turnedAway = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            connection.start(queue: queue)
            head(connection, Data())
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        queue.sync {
            host?.connection.cancel()
            for caller in callers.values { caller.connection.cancel() }
            host = nil
            callers = [:]
        }
    }

    func url() async throws -> URL {
        for _ in 0..<400 where (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        guard let port = listener.port?.rawValue, port != 0, let url = URL(string: "http://127.0.0.1:\(port)") else { throw URLError(.cannotConnectToHost) }
        return url
    }

    /// The computer is on the relay and has said which devices may reach it.
    var ready: Bool { queue.sync { host != nil && !devices.isEmpty } }
    /// Bytes of stream frames passed from one side to the other.
    var carried: Int { queue.sync { bytes } }
    /// Callers refused for a credential the computer didn't list.
    var refused: Int { queue.sync { turnedAway } }

    private func head(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
            let buffer = buffer + (data ?? Data())
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return done || error != nil ? connection.cancel() : head(connection, buffer)
            }
            let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let key = headers["sec-websocket-key"] else { return refuse(connection) }
            let socket: Socket
            switch path {
            case "/v1/tunnel/mac":
                socket = Socket(connection, slot: 0, device: nil)
            case "/v1/tunnel/phone":
                guard let device = admitted(headers["authorization"]) else { return refuse(connection) }
                slots += 1
                socket = Socket(connection, slot: slots, device: device)
            default:
                return refuse(connection)
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            connection.send(content: Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8),
                            completion: .idempotent)
            if socket.slot == 0 {
                host?.connection.cancel()
                host = socket
                for caller in callers.values { send(text: #"{"type":"mac","online":true}"#, on: caller) }
            } else {
                callers[socket.slot] = socket
                send(text: #"{"type":"mac","online":\#(host != nil)}"#, on: socket)
            }
            socket.buffer = Data(buffer[end.upperBound...])
            read(socket)
        }
    }

    /// `Bearer d1.<install>.<device>.<secret>`: the device, when the computer listed it with that secret's hash.
    private func admitted(_ header: String?) -> String? {
        let prefix = "Bearer d1."
        guard let header, header.hasPrefix(prefix) else { return nil }
        let parts = header.dropFirst(prefix.count).split(separator: ".").map(String.init)
        guard parts.count == 3, let secret = Secret.base64url(parts[2]), devices[parts[1]] == Secret.base64url(Data(SHA256.hash(data: secret))) else {
            return nil
        }
        return parts[1]
    }

    private func refuse(_ connection: NWConnection) {
        turnedAway += 1
        let body = #"{"error":{"code":"unauthorized","message":"Unknown device"}}"#
        let reply = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func read(_ socket: Socket) {
        while let (fin, opcode, payload) = Self.frame(&socket.buffer) {
            if opcode != 0 { socket.opcode = opcode }
            socket.message.append(payload)
            guard fin else { continue }
            let message = socket.message
            socket.message = Data()
            switch socket.opcode {
            case 0x1: text(String(decoding: message, as: UTF8.self), from: socket)
            case 0x2: frame(message, from: socket)
            case 0x8: return gone(socket)
            case 0x9: write(0xA, message, on: socket)
            default: break
            }
        }
        socket.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, error in
            if let data { socket.buffer.append(data) }
            guard !done, error == nil else { return gone(socket) }
            read(socket)
        }
    }

    private func text(_ text: String, from socket: Socket) {
        if text == "ping" { return send(text: "pong", on: socket) }
        guard socket.slot == 0, let control = try? JSONDecoder().decode(TunnelControl.self, from: Data(text.utf8)), control.type == "devices" else { return }
        devices = Dictionary((control.devices ?? []).map { ($0.id, $0.secretHash) }) { first, _ in first }
    }

    private func frame(_ data: Data, from socket: Socket) {
        guard let frame = TunnelFrame(data) else { return }
        if socket.slot == 0 {
            guard let caller = callers[Int(frame.stream >> 16)] else {
                if frame.kind != .reset, let host { write(0x2, TunnelFrame.reset(frame.stream, "gone").encoded, on: host) }
                return
            }
            bytes += frame.payload.count
            write(0x2, TunnelFrame(frame.kind, frame.stream & 0xffff, frame.payload).encoded, on: caller)
        } else {
            let stream = UInt32(socket.slot) << 16 | frame.stream & 0xffff
            guard let host else {
                if frame.kind != .reset { write(0x2, TunnelFrame.reset(frame.stream, "mac_offline").encoded, on: socket) }
                return
            }
            bytes += frame.payload.count
            let payload = frame.kind == .open ? Data(#"{"device":"\#(socket.device ?? "")"}"#.utf8) : frame.payload
            write(0x2, TunnelFrame(frame.kind, stream, payload).encoded, on: host)
        }
    }

    private func gone(_ socket: Socket) {
        socket.connection.cancel()
        if socket.slot == 0 {
            guard host === socket else { return }
            host = nil
            for caller in callers.values { send(text: #"{"type":"mac","online":false}"#, on: caller) }
        } else if callers[socket.slot] === socket {
            callers[socket.slot] = nil
            if let host { send(text: #"{"type":"gone","slot":\#(socket.slot)}"#, on: host) }
        }
    }

    private func send(text: String, on socket: Socket) { write(0x1, Data(text.utf8), on: socket) }

    /// An unmasked frame, as a server sends one.
    private func write(_ opcode: UInt8, _ payload: Data, on socket: Socket) {
        var head = Data([0x80 | opcode])
        switch payload.count {
        case ..<126: head.append(UInt8(payload.count))
        case ..<65536: head.append(contentsOf: [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        default: head.append(127); head.append(contentsOf: (0..<8).reversed().map { UInt8(truncatingIfNeeded: payload.count >> ($0 * 8)) })
        }
        socket.connection.send(content: head + payload, completion: .idempotent)
    }

    /// The next whole frame at the front of `buffer`, unmasked, and removed from it; nil until one has arrived.
    private static func frame(_ buffer: inout Data) -> (fin: Bool, opcode: UInt8, payload: Data)? {
        let bytes = [UInt8](buffer.prefix(14))
        guard bytes.count >= 2 else { return nil }
        var length = Int(bytes[1] & 0x7f), at = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3]); at = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }; at = 10
        }
        let masked = bytes[1] & 0x80 != 0
        guard buffer.count >= at + (masked ? 4 : 0) + length else { return nil }
        let start = buffer.startIndex
        let mask = masked ? [UInt8](buffer[(start + at)..<(start + at + 4)]) : []
        at += mask.count
        var payload = [UInt8](buffer[(start + at)..<(start + at + length)])
        if masked { for index in payload.indices { payload[index] ^= mask[index % 4] } }
        buffer = Data(buffer[(start + at + length)...])
        return (bytes[0] & 0x80 != 0, bytes[0] & 0x0f, Data(payload))
    }
}
