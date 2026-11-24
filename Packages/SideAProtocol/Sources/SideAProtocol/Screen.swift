import Foundation

public extension Capability {
    static let screen = Self(rawValue: "screen")
    /// The Mac's Screen switch is on now, so the phone asks for Face ID only when there is something to see.
    static let screenOn = Self(rawValue: "screen.on")
}

public extension ConfirmPurpose {
    /// Opening `/v1/ws/screen/{mode}`, always, and only by the confirm key.
    static let screen = Self(rawValue: "screen")
}

public extension ConfirmMessage {
    /// The mode, so a signature to watch never lets the phone click.
    static func subject(screen mode: ScreenMode) -> String { mode.rawValue }
}

public enum ScreenProtocol {
    public static let version = 1
}

public struct ScreenMode: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let view = Self(rawValue: "view")
    /// Clicks, scrolls and keys too, while the Mac's Control switch is on.
    public static let control = Self(rawValue: "control")
}

public struct ScreenRoute: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// The LAN or the tailnet.
    public static let direct = Self(rawValue: "direct")
    public static let relay = Self(rawValue: "relay")
}

/// The most the Mac sends on a route; bitrate moves between `floor` and `bitrate` with what the socket drains.
public struct ScreenLimits: Codable, Hashable, Sendable {
    public let fps: Int
    /// Pixels on the frame's long side.
    public let longEdge: Int
    public let bitrate: Int
    public let floor: Int

    public init(fps: Int, longEdge: Int, bitrate: Int, floor: Int) {
        self.fps = fps; self.longEdge = longEdge; self.bitrate = bitrate; self.floor = floor
    }

    public static let direct = ScreenLimits(fps: 30, longEdge: 1600, bitrate: 8_000_000, floor: 400_000)
    /// One relay socket per Mac carries every phone, under a daily budget per install (protocol.md, Screen budget).
    public static let relay = ScreenLimits(fps: 15, longEdge: 1280, bitrate: 1_500_000, floor: 150_000)

    public static func on(_ route: ScreenRoute) -> ScreenLimits { route == .relay ? .relay : .direct }
}

public struct ScreenDisplay: Codable, Hashable, Sendable {
    public let id: UInt32
    public let name: String
    /// Points.
    public let width: Int
    public let height: Int
    public let main: Bool

    public init(id: UInt32, name: String, width: Int, height: Int, main: Bool) {
        self.id = id; self.name = name; self.width = width; self.height = height; self.main = main
    }
}

public struct ScreenWindow: Codable, Hashable, Sendable {
    public let id: UInt32
    public let app: String
    public let title: String?
    public let width: Int
    public let height: Int

    public init(id: UInt32, app: String, title: String?, width: Int, height: Int) {
        self.id = id; self.app = app; self.title = title; self.width = width; self.height = height
    }
}

/// `{"display": id}` or `{"window": id}`.
public enum ScreenTarget: Hashable, Sendable {
    case display(UInt32)
    case window(UInt32)
}

extension ScreenTarget: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        if let id = try c.optional("window", as: UInt32.self) { self = .window(id) } else { self = .display(try c.value("display")) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        switch self {
        case .display(let id): try c.put(id, "display")
        case .window(let id): try c.put(id, "window")
        }
    }
}

public struct ScreenControlReason: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Opened to watch.
    public static let view = Self(rawValue: "view")
    /// The Mac's Control switch is off.
    public static let off = Self(rawValue: "off")
    /// Side A isn't allowed in Privacy & Security › Accessibility.
    public static let accessibility = Self(rawValue: "accessibility")
    public static let locked = Self(rawValue: "locked")
    /// Typing was dropped: the window shown couldn't be brought to the front on the Mac.
    public static let focus = Self(rawValue: "focus")
}

public struct ScreenControlState: Codable, Hashable, Sendable {
    public let allowed: Bool
    public let reason: ScreenControlReason?
    public init(allowed: Bool, reason: ScreenControlReason? = nil) { self.allowed = allowed; self.reason = reason }
}

/// Sent just before the close code that goes with it.
public struct ScreenRefusal: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// 4403
    public static let off = Self(rawValue: "off")
    /// 4412: Side A isn't allowed in Privacy & Security › Screen Recording.
    public static let permission = Self(rawValue: "permission")
    /// 4409: another device started watching.
    public static let replaced = Self(rawValue: "replaced")
    /// 4410: ended on the Mac.
    public static let ended = Self(rawValue: "ended")
    /// 4500
    public static let failed = Self(rawValue: "failed")
    /// 4408: no feedback from the phone for a few seconds.
    public static let timeout = Self(rawValue: "timeout")

    public var closeCode: Int {
        switch self {
        case .off: 4403
        case .permission: 4412
        case .replaced: 4409
        case .ended: 4410
        case .timeout: 4408
        default: 4500
        }
    }

    public var message: String {
        switch self {
        case .off: "Screen is off on the Mac. Turn it on in Side A's Settings › iPhone › Screen."
        case .permission: "Allow Side A in System Settings › Privacy & Security › Screen Recording on the Mac, then quit and reopen Side A."
        case .replaced: "Another device started watching this Mac."
        case .ended: "Ended on the Mac."
        case .timeout: "The Mac stopped hearing from this iPhone."
        default: "The Mac couldn't capture its screen."
        }
    }
}

/// Only a socket that went away comes back by itself: a refusal stands until the person acts on it.
public enum ScreenClose: Equatable, Sendable {
    case closed
    case lost
    case unauthorized
    case unsupported
    case refused(ScreenRefusal)

    public static let refusals: [ScreenRefusal] = [.off, .permission, .replaced, .ended, .timeout, .failed]

    public init(code: Int) {
        switch code {
        case 1000: self = .closed
        case 4401: self = .unauthorized
        case 4426: self = .unsupported
        default: self = Self.refusals.first { $0.closeCode == code }.map(Self.refused) ?? .lost
        }
    }

    public var reconnects: Bool { self == .lost }
}

/// A named key, or one lowercase character for shortcuts (`"c"` with `.command` is Copy).
public struct ScreenKey: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let `return` = Self(rawValue: "return")
    public static let escape = Self(rawValue: "escape")
    public static let tab = Self(rawValue: "tab")
    public static let space = Self(rawValue: "space")
    public static let delete = Self(rawValue: "delete")
    public static let forwardDelete = Self(rawValue: "forwardDelete")
    public static let left = Self(rawValue: "left")
    public static let right = Self(rawValue: "right")
    public static let up = Self(rawValue: "up")
    public static let down = Self(rawValue: "down")
    public static let home = Self(rawValue: "home")
    public static let end = Self(rawValue: "end")
    public static let pageUp = Self(rawValue: "pageUp")
    public static let pageDown = Self(rawValue: "pageDown")
}

public struct ScreenModifier: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let command = Self(rawValue: "command")
    public static let option = Self(rawValue: "option")
    public static let control = Self(rawValue: "control")
    public static let shift = Self(rawValue: "shift")
}

/// `x` and `y` from 0 to 1 across the picture, top left first, so neither side needs the other's pixel sizes.
public struct ScreenPointer: Codable, Hashable, Sendable {
    public struct Kind: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let click = Self(rawValue: "click")
        public static let rightClick = Self(rawValue: "rightClick")
        public static let doubleClick = Self(rawValue: "doubleClick")
    }

    public let kind: Kind
    public let x: Double
    public let y: Double
    public init(kind: Kind, x: Double, y: Double) { self.kind = kind; self.x = x; self.y = y }
}

/// `dx` and `dy` are fractions of the picture the content follows, as under a finger.
public struct ScreenScroll: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let dx: Double
    public let dy: Double
    public init(x: Double, y: Double, dx: Double, dy: Double) { self.x = x; self.y = y; self.dx = dx; self.dy = dy }
}

public struct ScreenKeyPress: Codable, Hashable, Sendable {
    public let key: ScreenKey
    public let modifiers: [ScreenModifier]
    public init(key: ScreenKey, modifiers: [ScreenModifier] = []) { self.key = key; self.modifiers = modifiers }
}

public struct ScreenHello: Codable, Hashable, Sendable {
    public let version: Int
    /// The most pixels the phone can use; the route's limit applies too.
    public let maxWidth: Int
    public let maxHeight: Int
    public let codecs: [String]
    public init(version: Int = ScreenProtocol.version, maxWidth: Int, maxHeight: Int, codecs: [String] = ["h264"]) {
        self.version = version; self.maxWidth = maxWidth; self.maxHeight = maxHeight; self.codecs = codecs
    }
}

public struct ScreenStart: Codable, Hashable, Sendable {
    /// Nil: the window of `session` if the Mac finds one, else the main display.
    public let target: ScreenTarget?
    public let fps: Int?
    /// A hosted session's name.
    public let session: String?
    public init(target: ScreenTarget? = nil, fps: Int? = nil, session: String? = nil) { self.target = target; self.fps = fps; self.session = session }
}

/// Once a second, which is also how the Mac knows someone is still looking.
public struct ScreenFeedback: Codable, Hashable, Sendable {
    public let fps: Double
    /// Frames the phone couldn't decode since the last report.
    public let dropped: Int
    /// Milliseconds from the last `ping` to its `pong`. Over the relay, bytes wait in the tunnel where the Mac's own
    /// socket queue can't see them, so this is the Mac's one measure of how far behind the picture is.
    public let rtt: Double?
    public init(fps: Double, dropped: Int, rtt: Double? = nil) { self.fps = fps; self.dropped = dropped; self.rtt = rtt }
}

public struct ScreenReady: Codable, Hashable, Sendable {
    public let version: Int
    public let route: ScreenRoute
    public let displays: [ScreenDisplay]
    public let windows: [ScreenWindow]
    public let control: ScreenControlState
    public let limits: ScreenLimits
    public init(version: Int = ScreenProtocol.version, route: ScreenRoute, displays: [ScreenDisplay], windows: [ScreenWindow],
                control: ScreenControlState, limits: ScreenLimits) {
        self.version = version; self.route = route; self.displays = displays; self.windows = windows; self.control = control; self.limits = limits
    }
}

public struct ScreenStarted: Codable, Hashable, Sendable {
    public let target: ScreenTarget
    public let width: Int
    public let height: Int
    public let fps: Int
    public let codec: String
    public init(target: ScreenTarget, width: Int, height: Int, fps: Int, codec: String = "h264") {
        self.target = target; self.width = width; self.height = height; self.fps = fps; self.codec = codec
    }
}

public struct ScreenQuality: Codable, Hashable, Sendable {
    public let fps: Int
    public let bitrate: Int
    public let width: Int
    public let height: Int
    /// Held under what the picture could take: the relay's ceiling, or a socket that drains slowly.
    public let reduced: Bool
    public init(fps: Int, bitrate: Int, width: Int, height: Int, reduced: Bool) {
        self.fps = fps; self.bitrate = bitrate; self.width = width; self.height = height; self.reduced = reduced
    }
}

public struct ScreenRefused: Codable, Hashable, Sendable {
    public let reason: ScreenRefusal
    public let message: String
    public init(reason: ScreenRefusal, message: String) { self.reason = reason; self.message = message }
}

/// Text frames on `/v1/ws/screen/{mode}`, `{"type", "data"}` like every union.
public enum ScreenControl: Hashable, Sendable {
    // client → server
    case hello(ScreenHello)
    case start(ScreenStart)
    case keyframe
    case feedback(ScreenFeedback)
    /// Answered by `pong` behind every frame already queued, so the round trip includes the wait.
    case ping(t: Double)
    case pointer(ScreenPointer)
    case scroll(ScreenScroll)
    case key(ScreenKeyPress)
    case text(String)
    case bye
    // server → client
    case ready(ScreenReady)
    case started(ScreenStarted)
    case quality(ScreenQuality)
    case control(ScreenControlState)
    case pong(t: Double)
    case refused(ScreenRefused)
    case unknown(type: String)

    public static let maxText = 256

    public var type: String {
        switch self {
        case .hello: "hello"
        case .start: "start"
        case .keyframe: "keyframe"
        case .feedback: "feedback"
        case .ping: "ping"
        case .pointer: "pointer"
        case .scroll: "scroll"
        case .key: "key"
        case .text: "text"
        case .bye: "bye"
        case .ready: "ready"
        case .started: "started"
        case .quality: "quality"
        case .control: "control"
        case .pong: "pong"
        case .refused: "refused"
        case .unknown(let type): type
        }
    }
}

extension ScreenControl: Codable {
    private struct Time: Codable { let t: Double }
    private struct Text: Codable { let text: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let type = try c.value("type", as: String.self)
        func data<T: Decodable>(_: T.Type) throws -> T { try c.value("data") }
        switch type {
        case "hello": self = .hello(try data(ScreenHello.self))
        case "start": self = .start(try data(ScreenStart.self))
        case "keyframe": self = .keyframe
        case "feedback": self = .feedback(try data(ScreenFeedback.self))
        case "ping": self = .ping(t: try data(Time.self).t)
        case "pointer": self = .pointer(try data(ScreenPointer.self))
        case "scroll": self = .scroll(try data(ScreenScroll.self))
        case "key": self = .key(try data(ScreenKeyPress.self))
        case "text": self = .text(try data(Text.self).text)
        case "bye": self = .bye
        case "ready": self = .ready(try data(ScreenReady.self))
        case "started": self = .started(try data(ScreenStarted.self))
        case "quality": self = .quality(try data(ScreenQuality.self))
        case "control": self = .control(try data(ScreenControlState.self))
        case "pong": self = .pong(t: try data(Time.self).t)
        case "refused": self = .refused(try data(ScreenRefused.self))
        default: self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.put(type, "type")
        switch self {
        case .hello(let hello): try c.put(hello, "data")
        case .start(let start): try c.put(start, "data")
        case .feedback(let feedback): try c.put(feedback, "data")
        case .ping(let t), .pong(let t): try c.put(Time(t: t), "data")
        case .pointer(let pointer): try c.put(pointer, "data")
        case .scroll(let scroll): try c.put(scroll, "data")
        case .key(let key): try c.put(key, "data")
        case .text(let text): try c.put(Text(text: text), "data")
        case .ready(let ready): try c.put(ready, "data")
        case .started(let started): try c.put(started, "data")
        case .quality(let quality): try c.put(quality, "data")
        case .control(let control): try c.put(control, "data")
        case .refused(let refused): try c.put(refused, "data")
        case .keyframe, .bye, .unknown: break
        }
    }
}

/// A binary frame on `/v1/ws/screen/{mode}`, server → client. Integers are big-endian.
public enum ScreenFrame: Hashable, Sendable {
    /// `0x21`, codec, u16 width, u16 height, u8 count, then each parameter set as u16 length and bytes. Before every keyframe.
    case config(codec: UInt8, width: Int, height: Int, parameterSets: [Data])
    /// `0x22`, flags (bit 0 keyframe), u32 seq, u64 microseconds since the stream started, then AVCC NAL units.
    case video(seq: UInt32, keyframe: Bool, time: UInt64, data: Data)

    public static let h264: UInt8 = 1
    /// Below the Mac's 1 MiB socket queue; a bigger frame is dropped there and the next is a keyframe.
    public static let maxVideo = 900 * 1024

    public var data: Data {
        var out = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) } }
        switch self {
        case .config(let codec, let width, let height, let sets):
            out.append(0x21)
            out.append(codec)
            put(UInt16(clamping: width)); put(UInt16(clamping: height))
            out.append(UInt8(clamping: sets.count))
            for set in sets.prefix(255) {
                put(UInt16(clamping: set.count))
                out.append(set.prefix(Int(UInt16.max)))
            }
        case .video(let seq, let keyframe, let time, let data):
            out.append(0x22)
            out.append(keyframe ? 1 : 0)
            put(seq); put(time)
            out.append(data)
        }
        return out
    }

    /// Nil for an unknown tag or a short frame.
    public init?(_ data: Data) {
        let bytes = [UInt8](data)
        func int(_ at: Int, _ count: Int) -> UInt64 { bytes[at..<at + count].reduce(0) { $0 << 8 | UInt64($1) } }
        switch bytes.first {
        case 0x21 where bytes.count >= 7:
            var sets: [Data] = []
            var at = 7
            for _ in 0..<Int(bytes[6]) {
                guard at + 2 <= bytes.count else { return nil }
                let length = Int(int(at, 2))
                guard at + 2 + length <= bytes.count else { return nil }
                sets.append(Data(bytes[at + 2..<at + 2 + length]))
                at += 2 + length
            }
            self = .config(codec: bytes[1], width: Int(int(2, 2)), height: Int(int(4, 2)), parameterSets: sets)
        case 0x22 where bytes.count >= 14:
            self = .video(seq: UInt32(int(2, 4)), keyframe: bytes[1] & 1 != 0, time: int(6, 8), data: Data(bytes[14...]))
        default: return nil
        }
    }
}
