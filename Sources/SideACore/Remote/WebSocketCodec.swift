import Foundation
import SideAProtocol

/// RFC 6455, server side: the upgrade handshake and frames. Network.framework's WebSocket can't share a port with
/// plain HTTP, so REST and both sockets go through one handwritten upgrade on Side A's own TLS listener.
public enum WebSocketCodec {
    public typealias Opcode = WebSocketFrames.Opcode

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

    public static func acceptKey(_ key: String) -> String { WebSocketFrames.acceptKey(key) }

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
    public static func frame(_ opcode: Opcode, _ payload: Data) -> Data { WebSocketFrames.frame(opcode, payload, from: .server) }

    public static func frame(_ message: Message) -> Data {
        switch message {
        case .text(let text): frame(.text, Data(text.utf8))
        case .binary(let data): frame(.binary, data)
        case .ping(let data): frame(.ping, data)
        case .pong(let data): frame(.pong, data)
        case .close(let code, let reason):
            frame(.close, code.map { WebSocketFrames.closePayload($0, reason, maxReason: 123) } ?? Data())
        }
    }

    /// A push parser for client frames: masked, control frames short and whole, data frames reassembled.
    public struct Parser: Sendable {
        private var frames = WebSocketFrames(role: .server, maxMessage: 1 << 20, strict: true)
        private var failed = false

        public init() {}

        public mutating func feed(_ bytes: Data) -> [Result<Message, Failure>] {
            guard !failed else { return [] }
            frames.append(bytes)
            var out: [Result<Message, Failure>] = []
            while let next = frames.next() {
                let message = next.mapError { Failure($0.code, $0.reason) }.flatMap(Self.message)
                out.append(message)
                if case .failure = message {
                    failed = true
                    // Drops whatever was buffered behind the failure.
                    frames = WebSocketFrames(role: .server, maxMessage: 0, strict: true)
                    return out
                }
            }
            return out
        }

        private static func message(_ frame: (opcode: Opcode, payload: Data)) -> Result<Message, Failure> {
            let data = frame.payload
            switch frame.opcode {
            case .ping: return .success(.ping(data))
            case .pong: return .success(.pong(data))
            case .close:
                guard data.count != 1 else { return .failure(Failure(1002, "The close frame is malformed.")) }
                let code = data.count >= 2 ? UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1]) : nil
                guard let reason = String(data: data.dropFirst(2), encoding: .utf8) else { return .failure(Failure(1007, "The close reason isn't UTF-8.")) }
                return .success(.close(code: code, reason: reason))
            case .binary, .continuation: return .success(.binary(data))
            case .text:
                guard let text = String(data: data, encoding: .utf8) else { return .failure(Failure(1007, "A text message isn't UTF-8.")) }
                return .success(.text(text))
            }
        }
    }
}
