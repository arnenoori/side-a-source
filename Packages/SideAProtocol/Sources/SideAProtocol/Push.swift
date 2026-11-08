import CryptoKit
import Foundation

/// A push category: the relay's allowlist, each with a fixed `loc-key` shown when the Service Extension can't run.
public struct PushCategory: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Gate `.lockScreen` or `.unlock`.
    public static let request = Self(rawValue: "REQUEST")
    /// Gate `.biometric`.
    public static let requestDestructive = Self(rawValue: "REQUEST_DESTRUCTIVE")
    public static let question = Self(rawValue: "QUESTION")
    public static let plan = Self(rawValue: "PLAN")
    public static let finished = Self(rawValue: "FINISHED")
    public static let limit = Self(rawValue: "LIMIT")
    public static let health = Self(rawValue: "HEALTH")
    /// Autopilot moved sessions, or no account has room. Only to a phone that said `rotation` in its `hello`.
    public static let rotation = Self(rawValue: "ROTATION")
    public static let test = Self(rawValue: "TEST")
    /// Relay `kind: "dismiss"` only; no envelope.
    public static let answered = Self(rawValue: "ANSWERED")
    /// Never travels: the Service Extension switches a `REQUEST` to it only when the authenticated payload says `gate: "lockScreen"`.
    public static let requestSafe = Self(rawValue: "REQUEST_SAFE")
    /// Never travels: Open only, for a request whose detail was cut to fit (`full: false`), so nothing is allowed unseen.
    public static let open = Self(rawValue: "OPEN")

    public var locKey: String? {
        switch self {
        case .request, .requestDestructive: "PUSH_REQUEST_FALLBACK"
        case .question: "PUSH_QUESTION_FALLBACK"
        case .plan: "PUSH_PLAN_FALLBACK"
        case .finished: "PUSH_FINISHED_FALLBACK"
        case .limit: "PUSH_LIMIT_FALLBACK"
        case .health: "PUSH_HEALTH_FALLBACK"
        case .rotation: "PUSH_ROTATION_FALLBACK"
        case .test: "PUSH_TEST_FALLBACK"
        case .answered: "PUSH_ANSWERED"
        default: nil
        }
    }

    /// The only changes decryption may make to a category: any request cut to fit becomes `OPEN`, and otherwise
    /// `REQUEST` becomes `REQUEST_SAFE` for a Lock Screen gate.
    public func local(for payload: PushPayload) -> PushCategory {
        if payload.kind == .request, payload.full == false, self == .request || self == .requestDestructive { return .open }
        return self == .request && payload.kind == .request && payload.gate == .lockScreen ? .requestSafe : self
    }
}

public extension Capability {
    /// From a phone's `hello`: it shows a FINISHED push without `sid` as the Mac's grouped Ready, with Open only, and opens
    /// that Mac's sessions from it. A phone without it gets one FINISHED push per turn.
    static let readyGroups = Self(rawValue: "ready.groups")
}

/// `PushPayload.t`: what the push is about.
public struct PushKind: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let request = Self(rawValue: "request")
    public static let question = Self(rawValue: "question")
    public static let plan = Self(rawValue: "plan")
    public static let finished = Self(rawValue: "finished")
    public static let limit = Self(rawValue: "limit")
    public static let health = Self(rawValue: "health")
    public static let rotation = Self(rawValue: "rotation")
    public static let test = Self(rawValue: "test")

    /// Waiting on an answer: a request, question or plan.
    public var asks: Bool { [.request, .question, .plan].contains(self) }
}

/// What the Mac seals into a push, at most 2,048 bytes before sealing. Tagged by `t`.
public struct PushPayload: Codable, Hashable, Sendable {
    public static let budget = 2048

    /// 1
    public let v: Int
    /// A `PushKind`.
    public let t: String
    /// `MacInfo.id`.
    public let mac: String
    public let sent: Timestamp
    // request (rid and sid also on question, plan, finished, health)
    public let rid: RequestID?
    public let sid: SessionKey?
    /// "Allow Bash" (`RemoteRequest.headline`); the session title on finished and health.
    public let title: String?
    /// "side-a · Work"
    public let subtitle: String?
    /// The command or detail, cut to fit; the flag's words on health.
    public let body: String?
    public let gate: AllowGate?
    public let risk: IslandRisk?
    public let riskReason: String?
    public let agent: AgentProvider?
    // question
    public let questions: [IslandQuestion]?
    // plan
    public let plan: String?
    /// False: the questions or plan didn't fit, so the notification offers Open only.
    public let full: Bool?
    // finished
    public let turnID: String?
    public let summary: String?
    // limit, and rotation: `title` says what happened, `account` and `resetsAt` which account is back and when
    public let account: String?
    public let window: String?
    public let percent: Int?
    public let resetsAt: Timestamp?
    /// True: an update to a notification already shown, so it comes without a sound. Nil from a Mac that never says.
    public let quiet: Bool?

    public var kind: PushKind { PushKind(rawValue: t) }

    public init(t: String, mac: String, sent: Timestamp, rid: RequestID? = nil, sid: SessionKey? = nil, title: String? = nil,
                subtitle: String? = nil, body: String? = nil, gate: AllowGate? = nil, risk: IslandRisk? = nil, riskReason: String? = nil,
                agent: AgentProvider? = nil, questions: [IslandQuestion]? = nil, plan: String? = nil, full: Bool? = nil,
                turnID: String? = nil, summary: String? = nil, account: String? = nil, window: String? = nil, percent: Int? = nil,
                resetsAt: Timestamp? = nil, quiet: Bool? = nil) {
        v = 1; self.t = t; self.mac = mac; self.sent = sent; self.rid = rid; self.sid = sid; self.title = title
        self.subtitle = subtitle; self.body = body; self.gate = gate; self.risk = risk; self.riskReason = riskReason
        self.agent = agent; self.questions = questions; self.plan = plan; self.full = full; self.turnID = turnID
        self.summary = summary; self.account = account; self.window = window; self.percent = percent; self.resetsAt = resetsAt
        self.quiet = quiet
    }
}

/// The per-device push key both sides derive at pairing (and at each rekey), then keep instead of the X25519 keys.
public struct PushKey: Sendable, Equatable {
    public let key: SymmetricKey
    /// 4 bytes: names the key in every envelope.
    public let keyID: Data

    public init(key: SymmetricKey, keyID: Data) { self.key = key; self.keyID = keyID }
    public static func == (a: Self, b: Self) -> Bool {
        a.keyID == b.keyID && a.key.withUnsafeBytes { Data($0) } == b.key.withUnsafeBytes { Data($0) }
    }

    /// `HKDF-SHA256(ikm: X25519(shared), salt: SHA-256(macPub ‖ devicePub ‖ installID ‖ deviceID), info: "SideA Remote push v1", 32)`;
    /// `keyID` is the first 4 bytes of SHA-256 of the salt. The ids go in as their UTF-8 text.
    public static func derive(_ privateKey: Curve25519.KeyAgreement.PrivateKey, peer: Curve25519.KeyAgreement.PublicKey,
                              macPublicKey: Data, devicePublicKey: Data, installID: String, deviceID: String) throws -> PushKey {
        let salt = Data(SHA256.hash(data: macPublicKey + devicePublicKey + Data(installID.utf8) + Data(deviceID.utf8)))
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("SideA Remote push v1".utf8), outputByteCount: 32)
        return PushKey(key: key, keyID: Data(SHA256.hash(data: salt).prefix(4)))
    }

    /// The raw 32 bytes, for the keychain.
    public var data: Data { key.withUnsafeBytes { Data($0) } }
}

/// `base64url(0x02 ‖ keyID(4) ‖ nonce(12) ‖ ciphertext ‖ tag(16))`, ChaCha20-Poly1305 under the device's push key,
/// with `AAD = 0x02 ‖ keyID ‖ category ‖ collapseID ‖ deviceID`, each of the three as a 2-byte big-endian length and its
/// UTF-8, so the relay can't move a payload to another category, request or device, nor shift bytes between fields.
/// Version 1 joined the fields bare; its envelopes no longer open.
public enum PushEnvelope {
    public enum Failure: Error, Equatable { case format, version, key }

    static let version: UInt8 = 0x02

    static func aad(_ keyID: Data, category: PushCategory, collapseID: String, deviceID: String) throws -> Data {
        var aad = Data([version]) + keyID
        for field in [category.rawValue, collapseID, deviceID].map({ Data($0.utf8) }) {
            guard field.count <= 0xffff else { throw Failure.format }
            aad += Data([UInt8(field.count >> 8), UInt8(field.count & 0xff)]) + field
        }
        return aad
    }

    public static func seal(_ plaintext: Data, with key: PushKey, category: PushCategory, collapseID: String, deviceID: String,
                            nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()) throws -> String {
        let box = try ChaChaPoly.seal(plaintext, using: key.key, nonce: nonce,
                                      authenticating: try aad(key.keyID, category: category, collapseID: collapseID, deviceID: deviceID))
        return (Data([version]) + key.keyID + box.combined).base64URL
    }

    public static func open(_ envelope: String, with key: PushKey, category: PushCategory, collapseID: String, deviceID: String) throws -> Data {
        guard let bytes = Data(base64URL: envelope), bytes.count >= 1 + 4 + 12 + 16 else { throw Failure.format }
        guard bytes.first == version else { throw Failure.version }
        let keyID = bytes.dropFirst().prefix(4)
        guard Data(keyID) == key.keyID else { throw Failure.key }
        let box = try ChaChaPoly.SealedBox(combined: bytes.dropFirst(5))
        return try ChaChaPoly.open(box, using: key.key, authenticating: try aad(Data(keyID), category: category, collapseID: collapseID, deviceID: deviceID))
    }
}

/// The Live Activity's content. ActivityKit pushes skip the Service Extension, so this reaches Apple and the relay
/// in plaintext: counts, times and opaque ids only. The phone looks up the words by `topRequest`.
public struct ActivityContentState: Codable, Hashable, Sendable {
    public let working: Int
    public let waiting: Int
    /// A random request id, or nil.
    public let topRequest: RequestID?
    /// Seconds since 2001, ActivityKit's default `Date` decoding, unlike every other moment on the wire.
    public let soonestReset: Double?
    /// 0–100.
    public let tightestPercent: Int?

    public init(working: Int, waiting: Int, topRequest: RequestID? = nil, soonestResetAt: Timestamp? = nil, tightestPercent: Int? = nil) {
        self.working = working; self.waiting = waiting; self.topRequest = topRequest
        soonestReset = soonestResetAt.map { $0 - Date.timeIntervalBetween1970AndReferenceDate }
        self.tightestPercent = tightestPercent
    }
}
