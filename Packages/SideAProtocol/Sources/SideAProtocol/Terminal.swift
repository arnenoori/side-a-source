import Foundation

/// The phone's terminal theme, so the Mac answers OSC 10/11 and the colour-scheme query with it.
public struct TermTheme: Codable, Hashable, Sendable {
    public struct Appearance: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let dark = Self(rawValue: "dark")
        public static let light = Self(rawValue: "light")
    }

    public let appearance: Appearance?
    /// "#rrggbb"
    public let fg: String?
    public let bg: String?

    public init(appearance: Appearance? = nil, fg: String? = nil, bg: String? = nil) {
        self.appearance = appearance; self.fg = fg; self.bg = bg
    }
}

/// Why a terminal ended.
public struct TermExitReason: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// The agent exited.
    public static let ended = Self(rawValue: "ended")
    /// A DELETE, or Quit in Side A.
    public static let killed = Self(rawValue: "killed")
    /// The pane vanished.
    public static let lost = Self(rawValue: "lost")
}

/// Control messages on `/v1/ws/term/{name}`, framed `{"type", "data"}` like every union.
public enum TermControl: Hashable, Sendable {
    // client → server
    /// `viewer` is a UUID per (device, terminal view), kept across reconnects.
    case hello(viewer: String, cols: Int, rows: Int, theme: TermTheme? = nil)
    case resize(cols: Int, rows: Int)
    // server → client
    /// `applied`: the last input seq written for this viewer in this epoch; nil when the server has no record of it.
    case ready(epoch: String, applied: UInt32?, cols: Int, rows: Int, owner: String)
    /// Every input up to `seq` is in the PTY. `error` "too_large" refuses that frame.
    case ack(seq: UInt32, error: String?)
    /// The size to render at; `owner` is "mac" or "phone".
    case size(cols: Int, rows: Int, owner: String)
    /// The Mac is in tmux copy mode.
    case mode(copy: Bool)
    /// Ended or killed; close 4410 follows.
    case exit(status: Int?, reason: TermExitReason)
    case unknown(type: String)

    public var type: String {
        switch self {
        case .hello: "hello"
        case .resize: "resize"
        case .ready: "ready"
        case .ack: "ack"
        case .size: "size"
        case .mode: "mode"
        case .exit: "exit"
        case .unknown(let type): type
        }
    }
}

extension TermControl: Codable {
    private struct Hello: Codable {
        let viewer: String; let cols: Int; let rows: Int
        let appearance: TermTheme.Appearance?; let fg: String?; let bg: String?
    }
    private struct Size: Codable { let cols: Int; let rows: Int }
    private struct Ready: Codable { let epoch: String; let applied: UInt32?; let cols: Int; let rows: Int; let owner: String }
    private struct Ack: Codable { let seq: UInt32; let error: String? }
    private struct Owned: Codable { let cols: Int; let rows: Int; let owner: String }
    private struct Mode: Codable { let copy: Bool }
    private struct Exit: Codable { let status: Int?; let reason: TermExitReason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let type = try c.value("type", as: String.self)
        func data<T: Decodable>(_: T.Type) throws -> T { try c.value("data") }
        switch type {
        case "hello":
            let h = try data(Hello.self)
            let theme = h.appearance == nil && h.fg == nil && h.bg == nil ? nil : TermTheme(appearance: h.appearance, fg: h.fg, bg: h.bg)
            self = .hello(viewer: h.viewer, cols: h.cols, rows: h.rows, theme: theme)
        case "resize": let s = try data(Size.self); self = .resize(cols: s.cols, rows: s.rows)
        case "ready": let r = try data(Ready.self); self = .ready(epoch: r.epoch, applied: r.applied, cols: r.cols, rows: r.rows, owner: r.owner)
        case "ack": let a = try data(Ack.self); self = .ack(seq: a.seq, error: a.error)
        case "size": let s = try data(Owned.self); self = .size(cols: s.cols, rows: s.rows, owner: s.owner)
        case "mode": self = .mode(copy: try data(Mode.self).copy)
        case "exit": let e = try data(Exit.self); self = .exit(status: e.status, reason: e.reason)
        default: self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.put(type, "type")
        switch self {
        case .hello(let viewer, let cols, let rows, let theme):
            try c.put(Hello(viewer: viewer, cols: cols, rows: rows, appearance: theme?.appearance, fg: theme?.fg, bg: theme?.bg), "data")
        case .resize(let cols, let rows): try c.put(Size(cols: cols, rows: rows), "data")
        case .ready(let epoch, let applied, let cols, let rows, let owner):
            try c.put(Ready(epoch: epoch, applied: applied, cols: cols, rows: rows, owner: owner), "data")
        case .ack(let seq, let error): try c.put(Ack(seq: seq, error: error), "data")
        case .size(let cols, let rows, let owner): try c.put(Owned(cols: cols, rows: rows, owner: owner), "data")
        case .mode(let copy): try c.put(Mode(copy: copy), "data")
        case .exit(let status, let reason): try c.put(Exit(status: status, reason: reason), "data")
        case .unknown: break
        }
    }
}

/// A binary frame on `/v1/ws/term/{name}`.
public enum TermFrame: Hashable, Sendable {
    /// Server → client: `0x01` then raw PTY bytes, at most 32 KiB.
    case output(Data)
    /// Client → server: `0x02`, u32 big-endian `seq`, then bytes, at most 16 KiB.
    case input(seq: UInt32, bytes: Data)

    public static let maxOutput = 32 * 1024
    public static let maxInput = 16 * 1024

    public var data: Data {
        switch self {
        case .output(let bytes): return Data([0x01]) + bytes
        case .input(let seq, let bytes):
            return Data([0x02, UInt8(seq >> 24), UInt8(seq >> 16 & 0xff), UInt8(seq >> 8 & 0xff), UInt8(seq & 0xff)]) + bytes
        }
    }

    /// Nil for an unknown tag or a short input header.
    public init?(_ data: Data) {
        let bytes = [UInt8](data)
        switch bytes.first {
        case 0x01: self = .output(Data(bytes.dropFirst()))
        case 0x02 where bytes.count >= 5:
            let seq = bytes[1...4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            self = .input(seq: seq, bytes: Data(bytes.dropFirst(5)))
        default: return nil
        }
    }

    /// Input frames for a paste, each at most 16 KiB, never splitting a UTF-8 sequence.
    public static func inputs(_ text: Data, from seq: UInt32) -> [TermFrame] {
        var frames: [TermFrame] = []
        var start = text.startIndex
        var next = seq
        while start < text.endIndex {
            var end = min(start + maxInput, text.endIndex)
            // Back up over continuation bytes (10xxxxxx) so the cut falls on a character boundary.
            if end < text.endIndex {
                while end > start, text[end] & 0xC0 == 0x80 { end -= 1 }
                if end == start { end = min(start + maxInput, text.endIndex) }
            }
            frames.append(.input(seq: next, bytes: text[start..<end]))
            next &+= 1
            start = end
        }
        return frames
    }
}
