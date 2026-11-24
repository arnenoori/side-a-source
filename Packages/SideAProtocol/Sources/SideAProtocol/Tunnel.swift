import Foundation

/// One binary message on a relay tunnel socket: `type u8 | stream u32 big-endian | payload`.
/// What a stream carries is the phone's TLS to the Mac; the relay never reads it.
public struct TunnelFrame: Sendable, Equatable {
    public enum Kind: UInt8, Sendable { case open = 1, data, fin, reset, credit }

    public static let header = 5
    public static let maxPayload = 32 << 10

    public let kind: Kind
    public let stream: UInt32
    public let payload: Data

    public init(_ kind: Kind, _ stream: UInt32, _ payload: Data = Data()) {
        self.kind = kind; self.stream = stream; self.payload = payload
    }

    public static func credit(_ stream: UInt32, _ bytes: Int) -> TunnelFrame {
        var value = UInt32(clamping: bytes).bigEndian
        return TunnelFrame(.credit, stream, Data(bytes: &value, count: 4))
    }

    public static func reset(_ stream: UInt32, _ reason: String) -> TunnelFrame {
        TunnelFrame(.reset, stream, Data(reason.utf8.prefix(64)))
    }

    /// nil for anything the relay would also refuse.
    public init?(_ data: Data) {
        let bytes = [UInt8](data.prefix(Self.header))
        guard data.count >= Self.header, data.count <= Self.header + Self.maxPayload, let kind = Kind(rawValue: bytes[0]) else { return nil }
        self.kind = kind
        stream = UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 8 | UInt32(bytes[4])
        payload = Data(data.dropFirst(Self.header))
    }

    public var encoded: Data {
        var data = Data([kind.rawValue, UInt8(stream >> 24), UInt8(stream >> 16 & 0xff), UInt8(stream >> 8 & 0xff), UInt8(stream & 0xff)])
        data.append(payload)
        return data
    }

    /// A CREDIT frame's bytes.
    public var granted: Int? {
        guard kind == .credit, payload.count == 4 else { return nil }
        return payload.reduce(0) { $0 << 8 | Int($1) }
    }

    public var reason: String { String(decoding: payload, as: UTF8.self) }
}

/// The tunnel's text messages, `{"type": …}`. Each side reads only the ones meant for it.
public struct TunnelControl: Codable, Sendable, Equatable {
    public struct Device: Codable, Sendable, Equatable {
        public let id: String
        /// base64url(SHA-256(deviceSecret)), as the Mac has it from pairing.
        public let secretHash: String
        public init(id: String, secretHash: String) { self.id = id; self.secretHash = secretHash }
    }

    /// `devices`, `pairing`, `watch`, `goodbye` (Mac → relay); `gone` (relay → Mac); `mac` (relay → phone).
    public let type: String
    public var devices: [Device]?
    public var ticketHash: String?
    public var expiresAt: Double?
    public var slot: Int?
    public var online: Bool?
    /// `goodbye`: `quit`, `off` or `sleep`. A Mac that leaves without one is gone quiet to the relay after ten minutes.
    public var reason: String?

    public init(type: String, devices: [Device]? = nil, ticketHash: String? = nil, expiresAt: Double? = nil, slot: Int? = nil, online: Bool? = nil) {
        self.type = type; self.devices = devices; self.ticketHash = ticketHash; self.expiresAt = expiresAt; self.slot = slot; self.online = online
    }

    /// First on every connection: this Mac can be watched, so the relay may tell the phones if it goes quiet.
    public static let watch = TunnelControl(type: "watch")

    /// Why the Mac is leaving on purpose: the relay doesn't call a Mac that quit, or turned Remote off, quiet at all, and
    /// gives one that is going to sleep a day.
    public static func goodbye(_ reason: String) -> TunnelControl {
        var control = TunnelControl(type: "goodbye")
        control.reason = reason
        return control
    }

    /// What `goodbye` may say.
    public enum Goodbye {
        public static let quit = "quit", off = "off", sleep = "sleep"
    }

    public var text: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }

    public init?(text: String) {
        guard let value = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)) else { return nil }
        self = value
    }
}
