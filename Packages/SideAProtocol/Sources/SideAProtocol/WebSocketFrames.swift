import CryptoKit
import Foundation

/// RFC 6455 framing for both ends: the Mac's server and the phone's client. A server sends unmasked frames and
/// requires masked ones; a client the reverse. Fragments are joined; control frames come out as they arrive.
/// Interpreting text, close payloads and errors is the caller's.
public struct WebSocketFrames: Sendable {
    public enum Opcode: UInt8, Sendable { case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10 }
    public enum Role: Sendable { case server, client }

    public enum Violation: Error, Sendable, Equatable {
        case reservedBits, unknownOpcode, masking, malformedLength, splitControl, tooLarge, orphanContinuation, interleaved

        /// The close code and reason the server sends for it.
        public var code: UInt16 { self == .tooLarge ? 1009 : 1002 }
        public var reason: String {
            switch self {
            case .reservedBits: "Reserved bits are set."
            case .unknownOpcode: "Unknown opcode."
            case .masking: "Client frames must be masked."
            case .malformedLength: "The frame length is malformed."
            case .splitControl: "Control frames are short and whole."
            case .tooLarge: "The message is too large."
            case .orphanContinuation: "A continuation frame has nothing to continue."
            case .interleaved: "A new message started inside a fragmented one."
            }
        }
    }

    private let role: Role
    private let maxMessage: Int
    private let strict: Bool
    private var buffer = Data()
    /// Bytes of `buffer` already decoded; dropped on the next `append` rather than per frame.
    private var cursor = 0
    private var fragmentOpcode: Opcode?
    private var fragments = Data()

    /// `strict` rejects from the header alone: reserved bits, unknown opcodes, split or long control frames, and a
    /// frame that would take the message past `maxMessage`. Lenient checks the opcode once the payload is in,
    /// accepts any control frame, and checks the joined message after each continuation.
    public init(role: Role, maxMessage: Int, strict: Bool) {
        self.role = role
        self.maxMessage = maxMessage
        self.strict = strict
    }

    public mutating func append(_ bytes: Data) {
        if cursor > 0 {
            if cursor == buffer.count { buffer.removeAll(keepingCapacity: true) } else { buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + cursor) }
            cursor = 0
        }
        buffer.append(bytes)
    }

    /// The next whole message or control frame, nil until more bytes arrive. A violation drops the buffered bytes.
    public mutating func next() -> Result<(opcode: Opcode, payload: Data), Violation>? {
        while true {
            switch frame() {
            case .none: return nil
            case .failure(let violation)?:
                buffer.removeAll(); cursor = 0
                return .failure(violation)
            case .success(let frame?)?: return .success(frame)
            case .success(nil)?: continue
            }
        }
    }

    /// `.success(nil)`: a fragment was taken in.
    private mutating func frame() -> Result<(opcode: Opcode, payload: Data)?, Violation>? {
        let base = buffer.startIndex + cursor
        let available = buffer.count - cursor
        guard available >= 2 else { return nil }
        let b0 = buffer[base], b1 = buffer[base + 1]
        let fin = b0 & 0x80 != 0
        let known = Opcode(rawValue: b0 & 0x0F)
        if strict {
            guard b0 & 0x70 == 0 else { return .failure(.reservedBits) }
            guard known != nil else { return .failure(.unknownOpcode) }
        }
        let masked = b1 & 0x80 != 0
        guard masked == (role == .server) else { return .failure(.masking) }
        var length = UInt64(b1 & 0x7F)
        var offset = 2
        if length == 126 {
            guard available >= 4 else { return nil }
            length = UInt64(buffer[base + 2]) << 8 | UInt64(buffer[base + 3])
            offset = 4
        } else if length == 127 {
            guard available >= 10 else { return nil }
            length = (2..<10).reduce(0) { $0 << 8 | UInt64(buffer[base + $1]) }
            offset = 10
            guard length >> 63 == 0 else { return .failure(.malformedLength) }
        }
        let control = b0 & 0x08 != 0
        if strict, control {
            guard fin, length <= 125 else { return .failure(.splitControl) }
        }
        guard length <= UInt64(maxMessage), !strict || fragments.count + Int(length) <= maxMessage else { return .failure(.tooLarge) }
        let maskAt = offset
        if masked { offset += 4 }
        guard available >= offset + Int(length) else { return nil }
        let start = base + offset
        var payload = buffer.subdata(in: start..<start + Int(length))
        if masked {
            let key = (buffer[base + maskAt], buffer[base + maskAt + 1], buffer[base + maskAt + 2], buffer[base + maskAt + 3])
            payload.withUnsafeMutableBytes { Self.mask($0, key) }
        }
        cursor += offset + Int(length)
        guard let opcode = known else { return .failure(.unknownOpcode) }

        switch opcode {
        case .close, .ping, .pong: return .success((opcode, payload))
        case .text, .binary:
            guard fragmentOpcode == nil else { return .failure(.interleaved) }
            guard fin else { fragmentOpcode = opcode; fragments = payload; return .success(nil) }
            return .success((opcode, payload))
        case .continuation:
            guard let started = fragmentOpcode else { return .failure(.orphanContinuation) }
            fragments.append(payload)
            guard fragments.count <= maxMessage else { return .failure(.tooLarge) }
            guard fin else { return .success(nil) }
            defer { fragmentOpcode = nil; fragments = Data() }
            return .success((started, fragments))
        }
    }

    /// One unfragmented frame; a client's gets a fresh random mask.
    public static func frame(_ opcode: Opcode, _ payload: Data, from role: Role) -> Data {
        let masked = role == .client
        var out = Data(capacity: 14 + payload.count)
        out.append(0x80 | opcode.rawValue)
        let bit: UInt8 = masked ? 0x80 : 0
        switch payload.count {
        case ..<126: out.append(bit | UInt8(payload.count))
        case ..<65536: out.append(contentsOf: [bit | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        default:
            out.append(bit | 127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF)) }
        }
        guard masked else { out.append(payload); return out }
        let key = (UInt8.random(in: 0...255), UInt8.random(in: 0...255), UInt8.random(in: 0...255), UInt8.random(in: 0...255))
        out.append(contentsOf: [key.0, key.1, key.2, key.3])
        let body = out.count
        out.append(payload)
        out.withUnsafeMutableBytes { Self.mask(UnsafeMutableRawBufferPointer(rebasing: $0[body...]), key) }
        return out
    }

    /// A close frame's payload: the code, then at most `maxReason` bytes of reason.
    public static func closePayload(_ code: UInt16, _ reason: String, maxReason: Int) -> Data {
        Data([UInt8(code >> 8), UInt8(code & 0xFF)]) + Data(reason.utf8.prefix(maxReason))
    }

    /// `Sec-WebSocket-Accept` for a `Sec-WebSocket-Key`.
    public static func acceptKey(_ key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    private static func mask(_ bytes: UnsafeMutableRawBufferPointer, _ key: (UInt8, UInt8, UInt8, UInt8)) {
        var i = 0
        let count = bytes.count
        while i + 4 <= count {
            bytes[i] ^= key.0; bytes[i + 1] ^= key.1; bytes[i + 2] ^= key.2; bytes[i + 3] ^= key.3
            i += 4
        }
        if i < count { bytes[i] ^= key.0 }
        if i + 1 < count { bytes[i + 1] ^= key.1 }
        if i + 2 < count { bytes[i + 2] ^= key.2 }
    }
}
