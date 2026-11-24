import CryptoKit
import Foundation
import Network
@testable import SideA
import SideACore
import Testing

@Suite(.serialized)
struct TunnelClientTests {
    final class Relay: @unchecked Sendable {
        let listener: NWListener
        let queue = DispatchQueue(label: "TunnelClientTests.Relay")
        let clock: TimeInterval
        let opened: TimeInterval, known: Bool
        private let lock = NSLock()
        private var live: [NWConnection] = []
        private var _answers: [Int] = []
        var answers: [Int] { lock.withLock { _answers } }
        let (said, say) = AsyncStream<String>.makeStream()

        init(clock: TimeInterval = 0, opened: TimeInterval = 0, known: Bool = true) throws {
            self.clock = clock; self.opened = opened; self.known = known
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return connection.cancel() }
                connection.start(queue: queue)
                head(connection, Data())
            }
            listener.start(queue: queue)
        }

        deinit {
            listener.cancel()
            for connection in live { connection.cancel() }
        }

        func url() async throws -> URL {
            for _ in 0..<200 where (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(5)) }
            return URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!
        }

        func drop() {
            queue.sync {
                for connection in live { connection.cancel() }
                live = []
            }
        }

        private func head(_ connection: NWConnection, _ buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
                let buffer = buffer + (data ?? Data())
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    return done || error != nil ? connection.cancel() : head(connection, buffer)
                }
                var headers: [String: String] = [:]
                for line in String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let now = Date().addingTimeInterval(clock)
                let ts = headers["authorization"]?.components(separatedBy: ", ").first { $0.hasPrefix("ts=") }.flatMap { Double($0.dropFirst(3)) } ?? 0
                guard known, abs(now.timeIntervalSince1970 - ts) <= 120, let key = headers["sec-websocket-key"] else {
                    lock.withLock { _answers.append(401) }
                    let body = #"{"error":{"code":"unauthorized","message":""}}"#
                    let reply = "HTTP/1.1 401 Unauthorized\r\nDate: \(Self.http(now))\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    return connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
                lock.withLock { _answers.append(101) }
                live.append(connection)
                let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                let reply = "HTTP/1.1 101 Switching Protocols\r\nDate: \(Self.http(now.addingTimeInterval(-opened)))\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                connection.send(content: Data(reply.utf8), completion: .idempotent)
                frames(connection, Data(buffer[end.upperBound...]))
            }
        }

        private func frames(_ connection: NWConnection, _ buffer: Data) {
            var buffer = buffer
            while let (text, rest) = Self.frame(buffer) {
                buffer = rest
                if text == "ping" { connection.send(content: Data([0x81, 4]) + Data("pong".utf8), completion: .idempotent) } else { say.yield(text) }
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
                guard !done, error == nil else { return }
                frames(connection, buffer + (data ?? Data()))
            }
        }

        static func frame(_ buffer: Data) -> (String, Data)? {
            let bytes = [UInt8](buffer)
            guard bytes.count >= 2 else { return nil }
            var length = Int(bytes[1] & 0x7f), at = 2
            if length == 126 {
                guard bytes.count >= 4 else { return nil }
                length = Int(bytes[2]) << 8 | Int(bytes[3]); at = 4
            } else if length == 127 {
                guard bytes.count >= 10 else { return nil }
                length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }; at = 10
            }
            let mask = bytes[1] & 0x80 != 0 ? Array(bytes[at..<min(at + 4, bytes.count)]) : []
            at += mask.count
            guard bytes.count >= at + length else { return nil }
            let payload = bytes[at..<at + length].enumerated().map { mask.isEmpty ? $1 : $1 ^ mask[$0 % 4] }
            return (String(decoding: payload, as: UTF8.self), Data(bytes[(at + length)...]))
        }

        static func http(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            return formatter.string(from: date)
        }
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _statuses: [TunnelClient.Status] = []
        private var _registers = 0
        var statuses: [TunnelClient.Status] { lock.withLock { _statuses } }
        var registers: Int { lock.withLock { _registers } }
        func add(_ status: TunnelClient.Status) { lock.withLock { _statuses.append(status) } }
        func registered() { lock.withLock { _registers += 1 } }

        func until(_ seconds: Double = 10, _ done: ([TunnelClient.Status]) -> Bool) async throws {
            if !(await eventually(seconds) { done(statuses) }) { Issue.record("still waiting after \(seconds * 6) s: \(statuses)") }
        }
    }

    func client(_ relay: Relay, _ seen: Seen) async throws -> TunnelClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let client = TunnelClient(base: try await relay.url(), key: Curve25519.Signing.PrivateKey(), session: URLSession(configuration: configuration),
                                  register: { seen.registered() }, target: { $0(nil) })
        client.statusChanged = { seen.add($0) }
        return client
    }

    static let unknown = TunnelClient.Status.waiting("The relay didn't recognise this Mac")

    @Test func aSocketThatRanLongReconnectsOnTheFirstTry() async throws {
        let relay = try Relay(opened: 600)
        let seen = Seen()
        let tunnel = try await client(relay, seen)
        defer { tunnel.stop() }
        tunnel.start()
        try await seen.until { $0.last == .connected }
        relay.drop()
        try await seen.until { $0.filter { $0 == .connected }.count == 2 || $0.contains(Self.unknown) }
        #expect(!seen.statuses.contains(Self.unknown))
        #expect(relay.answers == [101, 101])
        #expect(seen.registers == 1)
    }

    @Test func aMacAsksToBeWatchedAndSaysWhyItLeaves() async throws {
        let relay = try Relay()
        let seen = Seen()
        let tunnel = try await client(relay, seen)
        defer { tunnel.stop() }
        tunnel.start()
        var said = relay.said.makeAsyncIterator()
        #expect(await said.next() == #"{"type":"watch"}"#)
        try await seen.until { $0.last == .connected }
        tunnel.goodbye(TunnelControl.Goodbye.sleep)
        #expect(await said.next() == #"{"reason":"sleep","type":"goodbye"}"#)
        tunnel.stop(goodbye: TunnelControl.Goodbye.off)
        #expect(await said.next() == #"{"reason":"off","type":"goodbye"}"#)
    }

    @Test func aSkewedClockIsCorrectedWithoutCallingTheMacUnknown() async throws {
        let relay = try Relay(clock: 900)
        let seen = Seen()
        let tunnel = try await client(relay, seen)
        defer { tunnel.stop() }
        tunnel.start()
        try await seen.until { $0.last == .connected || $0.contains(Self.unknown) }
        #expect(!seen.statuses.contains(Self.unknown))
        #expect(!seen.statuses.contains { if case .waiting = $0 { true } else { false } })
        #expect(relay.answers == [401, 101])
        #expect(seen.registers == 1)
    }

    @Test func aRelayThatForgotTheMacStillSaysSo() async throws {
        let relay = try Relay(known: false)
        let seen = Seen()
        let tunnel = try await client(relay, seen)
        defer { tunnel.stop() }
        tunnel.start()
        try await seen.until { $0.contains(Self.unknown) }
        try await seen.until { _ in seen.registers >= 2 }
        #expect(relay.answers.allSatisfy { $0 == 401 })
    }

    @Test func aForgottenMacWithASkewedClockIsStillUnknown() async throws {
        let relay = try Relay(clock: -900, known: false)
        let seen = Seen()
        let tunnel = try await client(relay, seen)
        defer { tunnel.stop() }
        tunnel.start()
        try await seen.until { $0.contains(Self.unknown) }
        #expect(seen.statuses == [.connecting, Self.unknown])
        #expect(relay.answers == [401, 401])
    }

    @Test func theWindowMatchesTheRelays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!TunnelClient.outsideWindow(signed: 1_800_000_000, relay: now))
        #expect(!TunnelClient.outsideWindow(signed: 1_800_000_000 - 118, relay: now))
        // The relay refuses past 120 s; a Date cut to the second can read as 120 for that.
        #expect(TunnelClient.outsideWindow(signed: 1_800_000_000 - 120, relay: now))
        #expect(TunnelClient.outsideWindow(signed: 1_800_000_000 + 119, relay: now))
        #expect(TunnelClient.outsideWindow(signed: 1_800_000_000 - 600, relay: now))
    }
}
