import CryptoKit
import Foundation

/// A feature one side offers. The phone shows a feature only when the Mac's `Hello` lists it.
public struct Capability: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let events = Self(rawValue: "events")
    public static let transcriptStream = Self(rawValue: "transcript.stream")
    public static let images = Self(rawValue: "images")
    public static let diffs = Self(rawValue: "diffs")
    public static let answersQuestions = Self(rawValue: "answers.questions")
    public static let answersPlans = Self(rawValue: "answers.plans")
    public static let replyNote = Self(rawValue: "reply.note")
    public static let replyFollowUp = Self(rawValue: "reply.followUp")
    /// `RemoteReply.submit = .steer` reaches a hosted Codex turn mid-turn.
    public static let replySteer = Self(rawValue: "reply.steer")
    /// The Mac reaches Codex sessions through Codex's shared app server. With it, a Codex session that isn't hosted and
    /// lacks `SessionAbility.replyTerminal` was started outside that server, so replies wait until it finishes.
    public static let replyTerminal = Self(rawValue: "reply.terminal")
    /// The Mac has Claude's inbox hooks installed. With it, a Claude session that isn't hosted and lacks
    /// `SessionAbility.replyInbox` has no hook waiting yet: it started before the install and hasn't finished a turn since.
    public static let replyInbox = Self(rawValue: "reply.inbox")
    public static let interrupt = Self(rawValue: "interrupt")
    public static let uploads = Self(rawValue: "uploads")
    public static let hosted = Self(rawValue: "hosted")
    public static let terminal = Self(rawValue: "terminal")
    public static let continueOnPhone = Self(rawValue: "continueOnPhone")
    public static let push = Self(rawValue: "push")
    public static let liveActivity = Self(rawValue: "liveActivity")
    public static let codexLive = Self(rawValue: "codex.live")
    public static let search = Self(rawValue: "search")
    /// The Mac requires an `X-SideA-Confirm` signature for destructive and biometric-gated allows, the terminal and keys
    /// sent while a request waits. The phone signs whenever it has a `confirmKey`, whether or not the Mac says this.
    public static let confirmSigned = Self(rawValue: "confirm.signed")
    /// Replies, starts and session or Mac actions need `ConfirmPurpose.action` signatures too (`ConfirmPolicy`).
    public static let confirmActions = Self(rawValue: "confirm.actions")
    /// `POST /v1/sessions/{id}/settings` and `GET /v1/models`; each session's `settings.*` abilities say what it takes.
    public static let sessionSettings = Self(rawValue: "settings")
    /// `RemoteAnswer.allowMode` on requests that list `modes`.
    public static let answersMode = Self(rawValue: "answers.mode")
    /// `GET /v1/sessions/{id}/turns/{turnID}/diff`.
    public static let turnDiff = Self(rawValue: "turns.diff")
    /// `POST /v1/hosted/{name}/trust` answers a hosted session's folder-trust dialog (`HostedAttention.Kind.trust`).
    public static let hostedTrust = Self(rawValue: "hosted.trust")
}

public struct MacInfo: Codable, Hashable, Sendable {
    /// SHA-256 of machine-id, hex, first 16; the phone's key for this Mac.
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Where a Mac listens now, `host:port`. The phone updates its copy on every hello over the pinned key.
public struct Endpoints: Codable, Hashable, Sendable {
    /// The primary address: the tailnet one ("100.101.12.4:47800"), else the best LAN one when the Mac has no Tailscale.
    public let tailnet: String
    /// MagicDNS name with port, when the tailnet has MagicDNS.
    public let name: String?
    /// "192.168.1.20:47800", only with Wi-Fi pairing on; always `lans?.first`, for phones that predate `lans`.
    public let lan: String?
    /// Every LAN host:port the Mac listens on, best first; only with Wi-Fi pairing on.
    public let lans: [String]?
    public init(tailnet: String, name: String? = nil, lan: String? = nil, lans: [String]? = nil) {
        self.tailnet = tailnet; self.name = name; self.lan = lan ?? lans?.first; self.lans = lans
    }
}

/// `GET /v1/hello`, and inside `Welcome` and `PairResponse`.
public struct Hello: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let minProtocol: Int
    public let maxProtocol: Int
    /// "0.6.0"
    public let app: String
    public let build: Int
    public let mac: MacInfo
    @Sorted public var capabilities: Set<Capability>
    /// Below this the phone must update.
    public let minClientBuild: Int?
    /// Random per app launch.
    public let epoch: String
    public let serverTime: Timestamp
    /// Set only when a valid token was sent.
    public let paired: Bool?
    /// The Remote switch.
    public let remoteOn: Bool
    public let endpoints: Endpoints
    /// First 8 bytes of the SPKI SHA-256, hex: which TLS key is in use.
    public let keyID: String

    public init(protocolVersion: Int = ProtocolVersion.current, minProtocol: Int = 1, maxProtocol: Int = 1, app: String, build: Int, mac: MacInfo,
                capabilities: Set<Capability>, minClientBuild: Int? = nil, epoch: String, serverTime: Timestamp, paired: Bool? = nil,
                remoteOn: Bool = true, endpoints: Endpoints, keyID: String) {
        self.protocolVersion = protocolVersion; self.minProtocol = minProtocol; self.maxProtocol = maxProtocol; self.app = app
        self.build = build; self.mac = mac; self.capabilities = capabilities; self.minClientBuild = minClientBuild; self.epoch = epoch
        self.serverTime = serverTime; self.paired = paired; self.remoteOn = remoteOn; self.endpoints = endpoints; self.keyID = keyID
    }

    /// Nil when this client can talk to that Mac; otherwise which side has to update.
    public func needsUpdate(clientBuild: Int, protocol version: Int = ProtocolVersion.current) -> NeedsUpdate? {
        if maxProtocol < version { return .mac }
        if minProtocol > version || (minClientBuild ?? 0) > clientBuild { return .client }
        return nil
    }
    public enum NeedsUpdate: Sendable, Equatable { case mac, client }

    /// "1.0 (12) · protocol 1", for the version lines at the foot of Settings on both sides.
    public var versionLine: String { "\(Self.version(app, build: build)) · protocol \(protocolVersion)" }

    /// "1.0 (12)".
    public static func version(_ app: String, build: Int) -> String { "\(app) (\(build))" }
}

public struct DeviceInfo: Codable, Hashable, Sendable {
    /// "Arne's iPhone"
    public let name: String
    /// "iPhone18,1"
    public let model: String
    /// "iOS 27.0"
    public let system: String
    public let app: String
    public let build: Int
    @Sorted public var capabilities: Set<Capability>
    public init(name: String, model: String, system: String, app: String, build: Int, capabilities: Set<Capability>) {
        self.name = name; self.model = model; self.system = system; self.app = app; self.build = build; self.capabilities = capabilities
    }
}

/// `POST /v1/pair`.
public struct PairRequest: Codable, Hashable, Sendable {
    /// 8 Crockford base32 characters, from the QR code or typed; "-" and case are ignored.
    public let code: String
    public let device: DeviceInfo
    /// 16 random bytes, base64url; also the relay's deviceId.
    public let deviceID: String
    /// X25519, 32 raw bytes, base64url.
    public let devicePublicKey: String
    /// base64url(SHA-256(deviceSecret)); the secret (32 random bytes) stays on the phone.
    public let deviceSecretHash: String
    /// base64url SHA-256 of the SPKI the phone saw on this connection.
    public let serverKeyHash: String
    /// An old deviceID of this phone, removed when this pairing completes.
    public let replaces: String?
    /// base64url X9.63 uncompressed P-256 public key (65 bytes) of a Secure Enclave key usable only after Face ID
    /// (`.biometryCurrentSet`); verifies `ConfirmSignature`s signed `c`. Part of the comparison code, so a substituted one shows.
    public let confirmKey: String?
    /// The same for a Secure Enclave key usable while the phone is unlocked; verifies signatures signed `u`.
    public let unlockKey: String?
    public init(code: String, device: DeviceInfo, deviceID: String, devicePublicKey: String, deviceSecretHash: String, serverKeyHash: String,
                replaces: String? = nil, confirmKey: String? = nil, unlockKey: String? = nil) {
        self.code = code; self.device = device; self.deviceID = deviceID; self.devicePublicKey = devicePublicKey
        self.deviceSecretHash = deviceSecretHash; self.serverKeyHash = serverKeyHash; self.replaces = replaces
        self.confirmKey = confirmKey; self.unlockKey = unlockKey
    }
}

/// 202 from `POST /v1/pair`: approve on the Mac before `expiresAt`, then wait.
public struct PairPending: Codable, Hashable, Sendable {
    /// Lowercased UUID; names this attempt in the wait call and on the Mac.
    public let attemptID: String
    /// 16 random bytes from the Mac, base64url.
    public let nonce: String
    /// X25519 the Mac made for this device, 32 raw bytes, base64url.
    public let macPublicKey: String
    public let expiresAt: Timestamp
    public init(attemptID: String, nonce: String, macPublicKey: String, expiresAt: Timestamp) {
        self.attemptID = attemptID; self.nonce = nonce; self.macPublicKey = macPublicKey; self.expiresAt = expiresAt
    }
}

public struct RelayInfo: Codable, Hashable, Sendable {
    /// "https://push.getsidea.com"
    public let url: String
    /// The Mac's relay install id.
    public let installID: String
    /// 4 bytes, base64url: names the push key both sides derived.
    public let keyID: String
    public init(url: String, installID: String, keyID: String) { self.url = url; self.installID = installID; self.keyID = keyID }
}

/// 201 from `POST /v1/pair/{attemptID}/wait`. The only time the token exists in clear.
public struct PairResponse: Codable, Hashable, Sendable {
    /// "sa1_" + base64url(32 random bytes).
    public let token: String
    public let deviceID: String
    public let mac: MacInfo
    /// Nil when the Mac has no relay install yet.
    public let relay: RelayInfo?
    public let hello: Hello
    public init(token: String, deviceID: String, mac: MacInfo, relay: RelayInfo? = nil, hello: Hello) {
        self.token = token; self.deviceID = deviceID; self.mac = mac; self.relay = relay; self.hello = hello
    }
}

/// `POST /v1/devices/rekey`: fresh X25519 keys for the 30-day push-key rotation.
public struct RekeyRequest: Codable, Hashable, Sendable {
    public let devicePublicKey: String
    public init(devicePublicKey: String) { self.devicePublicKey = devicePublicKey }
}

public struct RekeyResponse: Codable, Hashable, Sendable {
    public let macPublicKey: String
    public let keyID: String
    public init(macPublicKey: String, keyID: String) { self.macPublicKey = macPublicKey; self.keyID = keyID }
}

/// What the phone lets the Mac notify it about; sent with every push registration.
public struct NotificationPrefs: Codable, Hashable, Sendable {
    public let requests: Bool, questions: Bool, plans: Bool, finished: Bool, limits: Bool
    public let timeSensitiveRequests: Bool
    public let liveActivity: Bool
    /// "Don't notify while I'm watching the session".
    public let suppressWhileWatching: Bool
    /// HEALTH pushes: a session stuck or stalled. True when a phone that predates it sends none.
    public let health: Bool
    /// ROTATION pushes: Autopilot moved sessions, or every account is out. Nil from a phone that predates it, which gets none.
    public let rotation: Bool?
    public init(requests: Bool = true, questions: Bool = true, plans: Bool = true, finished: Bool = true, limits: Bool = true,
                timeSensitiveRequests: Bool = true, liveActivity: Bool = true, suppressWhileWatching: Bool = true, health: Bool = true,
                rotation: Bool? = nil) {
        self.rotation = rotation
        self.requests = requests; self.questions = questions; self.plans = plans; self.finished = finished; self.limits = limits
        self.timeSensitiveRequests = timeSensitiveRequests; self.liveActivity = liveActivity; self.suppressWhileWatching = suppressWhileWatching
        self.health = health
    }

    private enum CodingKeys: String, CodingKey {
        case requests, questions, plans, finished, limits, timeSensitiveRequests, liveActivity, suppressWhileWatching, health, rotation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(requests: try c.decode(Bool.self, forKey: .requests), questions: try c.decode(Bool.self, forKey: .questions),
                  plans: try c.decode(Bool.self, forKey: .plans), finished: try c.decode(Bool.self, forKey: .finished),
                  limits: try c.decode(Bool.self, forKey: .limits), timeSensitiveRequests: try c.decode(Bool.self, forKey: .timeSensitiveRequests),
                  liveActivity: try c.decode(Bool.self, forKey: .liveActivity),
                  suppressWhileWatching: try c.decode(Bool.self, forKey: .suppressWhileWatching),
                  health: try c.decodeIfPresent(Bool.self, forKey: .health) ?? true,
                  rotation: try c.decodeIfPresent(Bool.self, forKey: .rotation))
    }
}

/// `POST /v1/devices/push`.
public struct PushRegistration: Codable, Hashable, Sendable {
    public struct Environment: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let sandbox = Self(rawValue: "sandbox")
        public static let production = Self(rawValue: "production")
    }
    /// What a registration from before `bundleID` and `apnsEnvironment` means: the App Store app.
    public static let defaultBundleID = "com.arnenoori.sidea.remote"

    /// Hex.
    public let apnsToken: String
    /// The app's main bundle id. The relay sends to it as the `apns-topic`, adding `.push-type.liveactivity`
    /// for Live Activity tokens. Debug builds are `com.arnenoori.sidea.remote.dev`.
    public let bundleID: String
    /// Fixed at build time (Debug sandbox, Release production), never read from the provisioning profile.
    public let apnsEnvironment: Environment
    /// Live Activity push-to-start.
    public let pushToStartToken: String?
    /// Activity id → update token.
    public let activityTokens: [String: String]
    public let prefs: NotificationPrefs
    public init(apnsToken: String, bundleID: String = Self.defaultBundleID, apnsEnvironment: Environment = .production,
                pushToStartToken: String? = nil, activityTokens: [String: String] = [:], prefs: NotificationPrefs = NotificationPrefs()) {
        self.apnsToken = apnsToken; self.bundleID = bundleID; self.apnsEnvironment = apnsEnvironment; self.pushToStartToken = pushToStartToken
        self.activityTokens = activityTokens; self.prefs = prefs
    }

    private enum CodingKeys: String, CodingKey {
        case apnsToken, bundleID, apnsEnvironment, pushToStartToken, activityTokens, prefs
        /// The name `apnsEnvironment` had before; read, never written.
        case environment
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let environment = try c.decodeIfPresent(Environment.self, forKey: .apnsEnvironment)
            ?? c.decodeIfPresent(Environment.self, forKey: .environment) ?? .production
        self.init(apnsToken: try c.decode(String.self, forKey: .apnsToken),
                  bundleID: try c.decodeIfPresent(String.self, forKey: .bundleID) ?? Self.defaultBundleID, apnsEnvironment: environment,
                  pushToStartToken: try c.decodeIfPresent(String.self, forKey: .pushToStartToken),
                  activityTokens: try c.decode([String: String].self, forKey: .activityTokens), prefs: try c.decode(NotificationPrefs.self, forKey: .prefs))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(apnsToken, forKey: .apnsToken)
        try c.encode(bundleID, forKey: .bundleID)
        try c.encode(apnsEnvironment, forKey: .apnsEnvironment)
        try c.encodeIfPresent(pushToStartToken, forKey: .pushToStartToken)
        try c.encode(activityTokens, forKey: .activityTokens)
        try c.encode(prefs, forKey: .prefs)
    }
}

/// The inputs to the six-digit comparison code both sides show while pairing. An agent that read
/// the code off the screen and raced the phone gets a different number, and so does a substituted TLS key.
public struct PairingTranscript: Codable, Hashable, Sendable {
    /// As typed or scanned; "-" and case are ignored.
    public let code: String
    /// base64url, from `PairPending`.
    public let nonce: String
    public let macPublicKey: String
    public let devicePublicKey: String
    /// base64url SHA-256 of the TLS SPKI: the Mac's own, or the one the phone pinned or saw.
    public let serverKeyHash: String
    /// `PairRequest.confirmKey` and `unlockKey`, when the phone sent them.
    public let confirmKey: String?
    public let unlockKey: String?
    /// The expected result, six digits; fixtures hold it so both sides are checked against the same number.
    public let comparisonCode: String

    public init(code: String, nonce: String, macPublicKey: String, devicePublicKey: String, serverKeyHash: String, confirmKey: String? = nil,
                unlockKey: String? = nil) throws {
        self.code = code; self.nonce = nonce; self.macPublicKey = macPublicKey; self.devicePublicKey = devicePublicKey
        self.serverKeyHash = serverKeyHash; self.confirmKey = confirmKey; self.unlockKey = unlockKey
        comparisonCode = try Self.comparisonCode(code: code, nonce: nonce, macPublicKey: macPublicKey, devicePublicKey: devicePublicKey,
                                                 serverKeyHash: serverKeyHash, confirmKey: confirmKey, unlockKey: unlockKey)
    }

    public enum Invalid: Error { case base64(String) }

    /// SHA-256 over the ASCII label "sidea-pair-v1", then each field as a 2-byte big-endian length and its
    /// bytes: the normalized code (UTF-8), the nonce, the Mac's key, the phone's key and the SPKI hash
    /// (raw bytes, decoded from base64url). When the phone sent either confirm key, the confirm key and then the unlock key
    /// follow, each empty when absent. With neither the code is what it was before confirm keys; a stripped key still
    /// changes the phone's code. The first 8 bytes of the digest as a big-endian UInt64,
    /// mod 1,000,000, zero-padded to six digits.
    public static func comparisonCode(code: String, nonce: String, macPublicKey: String, devicePublicKey: String,
                                      serverKeyHash: String, confirmKey: String? = nil, unlockKey: String? = nil) throws -> String {
        var fields = [Data(normalized(code).utf8)]
        var keys = [("nonce", nonce), ("macPublicKey", macPublicKey), ("devicePublicKey", devicePublicKey), ("serverKeyHash", serverKeyHash)]
        if confirmKey != nil || unlockKey != nil { keys += [("confirmKey", confirmKey ?? ""), ("unlockKey", unlockKey ?? "")] }
        for (name, value) in keys {
            guard let bytes = Data(base64URL: value) else { throw Invalid.base64(name) }
            fields.append(bytes)
        }
        var input = Data("sidea-pair-v1".utf8)
        for field in fields { input += Data([UInt8(field.count >> 8 & 0xff), UInt8(field.count & 0xff)]) + field }
        let digest = Array(SHA256.hash(data: input))
        let number = digest[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
        return String(format: "%06llu", number)
    }

    /// The pairing code as the Mac stores it: uppercase, without dashes or spaces.
    public static func normalized(_ code: String) -> String {
        code.uppercased().filter { $0 != "-" && !$0.isWhitespace }
    }

    /// "482 913", as both sides show it.
    public static func display(_ comparisonCode: String) -> String {
        "\(comparisonCode.prefix(3)) \(comparisonCode.dropFirst(3))"
    }
}

public extension Data {
    /// Decodes base64url, with or without padding.
    init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    /// base64url without padding.
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The TLS key pin: SHA-256 of the Mac's P-256 SubjectPublicKeyInfo, base64url. The Mac hashes its own
/// identity with this and puts it in the QR code (`fp`); the phone checks every connection against it.
public enum SPKI {
    /// The DER prefix of a P-256 SubjectPublicKeyInfo, before the 65-byte uncompressed point.
    static let p256Prefix = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08,
                                  0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00])

    /// From the key's X9.63 representation (`04 ‖ X ‖ Y`, what `SecKeyCopyExternalRepresentation` gives).
    public static func hash(p256 x963: Data) -> String? {
        guard x963.count == 65, x963.first == 0x04 else { return nil }
        return Data(SHA256.hash(data: p256Prefix + x963)).base64URL
    }

    public static func hash(_ key: P256.Signing.PublicKey) -> String { Data(SHA256.hash(data: key.derRepresentation)).base64URL }

    /// `Hello.keyID`: the first 8 bytes of the SPKI SHA-256, hex.
    public static func keyID(_ hash: String) -> String? {
        Data(base64URL: hash).map { $0.prefix(8).map { String(format: "%02x", $0) }.joined() }
    }
}
