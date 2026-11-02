import CryptoKit
import Foundation

/// RFC 6455, server side: the upgrade handshake and frames. Network.framework's WebSocket can't share a port with
/// plain HTTP, so REST and both sockets go through one handwritten upgrade on Side A's own TLS listener.
public enum WebSocketCodec {
    public enum Opcode: UInt8, Sendable { case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10 }

    public enum Message: Sendable, Equatable {
        case text(String)
        case binary(Data)
        case ping(Data)
        case pong(Data)
        case close(code: UInt16?, reason: String)
    }

    /// Why the server closes; `code` goes in the close frame.
    public struct Failure: Error, Sendable, Equatable {
        public let code: UInt16
        public let reason: String
        public init(_ code: UInt16, _ reason: String) { self.code = code; self.reason = reason }
    }

    public static func acceptKey(_ key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    /// The 101 for a valid upgrade, or the error to answer instead.
    public static func handshake(_ request: HTTPRequest) -> Result<HTTPResponse, HTTPError> {
        guard request.method == "GET" else { return .failure(HTTPError(405, "Upgrade with GET.")) }
        guard request.wantsUpgrade else { return .failure(HTTPError(426, "This path takes a WebSocket.")) }
        guard request.headers["Sec-WebSocket-Version"] == "13" else { return .failure(HTTPError(426, "Use WebSocket version 13.")) }
        guard let key = request.headers["Sec-WebSocket-Key"], Data(base64Encoded: key)?.count == 16 else {
            return .failure(HTTPError(400, "The WebSocket key is malformed."))
        }
        return .success(HTTPResponse(status: 101, headers: HTTPHeaders([("Upgrade", "websocket"), ("Connection", "Upgrade"),
                                                                        ("Sec-WebSocket-Accept", acceptKey(key))])))
    }

    /// Server frames are never masked and never fragmented.
    public static func frame(_ opcode: Opcode, _ payload: Data) -> Data {
        var out = Data([0x80 | opcode.rawValue])
        switch payload.count {
        case ..<126: out.append(UInt8(payload.count))
        case ..<65536: out.append(126); out.append(UInt8(payload.count >> 8)); out.append(UInt8(payload.count & 0xFF))
        default:
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF)) }
        }
        out.append(payload)
        return out
    }

    public static func frame(_ message: Message) -> Data {
        switch message {
        case .text(let text): frame(.text, Data(text.utf8))
        case .binary(let data): frame(.binary, data)
        case .ping(let data): frame(.ping, data)
        case .pong(let data): frame(.pong, data)
        case .close(let code, let reason):
            frame(.close, code.map { Data([UInt8($0 >> 8), UInt8($0 & 0xFF)]) + Data(reason.utf8.prefix(123)) } ?? Data())
        }
    }

    /// A push parser for client frames: masked, control frames short and whole, data frames reassembled.
    public struct Parser: Sendable {
        private let maxMessage = 1 << 20
        private var buffer = Data()
        private var fragments: (opcode: Opcode, data: Data)?
        private var failed = false

        public init() {}

        public mutating func feed(_ bytes: Data) -> [Result<Message, Failure>] {
            guard !failed else { return [] }
            buffer.append(bytes)
            var out: [Result<Message, Failure>] = []
            while true {
                switch next() {
                case .none: return out
                case .failure(let failure)?: failed = true; buffer = Data(); out.append(.failure(failure)); return out
                case .success(let message?)?: out.append(.success(message))
                case .success(nil)?: continue
                }
            }
        }

        /// nil: more bytes needed. `.success(nil)`: a fragment was taken in, nothing to hand out yet.
        private mutating func next() -> Result<Message?, Failure>? {
            let bytes = [UInt8](buffer.prefix(14))
            guard bytes.count >= 2 else { return nil }
            let fin = bytes[0] & 0x80 != 0
            guard bytes[0] & 0x70 == 0 else { return .failure(Failure(1002, "Reserved bits are set.")) }
            guard let opcode = Opcode(rawValue: bytes[0] & 0x0F) else { return .failure(Failure(1002, "Unknown opcode.")) }
            guard bytes[1] & 0x80 != 0 else { return .failure(Failure(1002, "Client frames must be masked.")) }
            var length = UInt64(bytes[1] & 0x7F)
            var offset = 2
            if length == 126 {
                guard bytes.count >= 4 else { return nil }
                length = UInt64(bytes[2]) << 8 | UInt64(bytes[3])
                offset = 4
            } else if length == 127 {
                guard bytes.count >= 10 else { return nil }
                length = bytes[2..<10].reduce(0) { $0 << 8 | UInt64($1) }
                offset = 10
                guard length >> 63 == 0 else { return .failure(Failure(1002, "The frame length is malformed.")) }
            }
            let control = opcode.rawValue >= 8
            if control {
                guard fin, length <= 125 else { return .failure(Failure(1002, "Control frames are short and whole.")) }
            }
            guard length <= UInt64(maxMessage), (fragments?.data.count ?? 0) + Int(length) <= maxMessage else {
                return .failure(Failure(1009, "The message is too large."))
            }
            guard bytes.count >= offset + 4 else { return nil }
            let mask = Array(bytes[offset..<offset + 4])
            offset += 4
            guard buffer.count >= offset + Int(length) else { return nil }
            let start = buffer.startIndex + offset
            var payload = [UInt8](buffer[start..<start + Int(length)])
            for i in payload.indices { payload[i] ^= mask[i & 3] }
            buffer = Data(buffer[(start + Int(length))...])
            let data = Data(payload)

            switch opcode {
            case .ping: return .success(.ping(data))
            case .pong: return .success(.pong(data))
            case .close:
                guard data.count != 1 else { return .failure(Failure(1002, "The close frame is malformed.")) }
                let code = data.count >= 2 ? UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1]) : nil
                guard let reason = String(data: data.dropFirst(2), encoding: .utf8) else { return .failure(Failure(1007, "The close reason isn't UTF-8.")) }
                return .success(.close(code: code, reason: reason))
            case .text, .binary:
                guard fragments == nil else { return .failure(Failure(1002, "A new message started inside a fragmented one.")) }
                if !fin { fragments = (opcode, data); return .success(nil) }
                return finish(opcode, data)
            case .continuation:
                guard var open = fragments else { return .failure(Failure(1002, "A continuation frame has nothing to continue.")) }
                open.data.append(data)
                if !fin { fragments = open; return .success(nil) }
                fragments = nil
                return finish(open.opcode, open.data)
            }
        }

        private func finish(_ opcode: Opcode, _ data: Data) -> Result<Message?, Failure> {
            guard opcode == .text else { return .success(.binary(data)) }
            guard let text = String(data: data, encoding: .utf8) else { return .failure(Failure(1007, "A text message isn't UTF-8.")) }
            return .success(.text(text))
        }
    }
}
