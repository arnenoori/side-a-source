import CryptoKit
import Foundation

/// What a signed confirm vouches for.
public struct ConfirmPurpose: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Answering a request the Mac rates destructive or gates.
    public static let allow = Self(rawValue: "allow")
    /// Opening `/v1/ws/term` on a session.
    public static let terminal = Self(rawValue: "terminal")
    /// A `.keys` reply.
    public static let keys = Self(rawValue: "keys")
    /// `POST /v1/sessions/{id}/settings`, and a `StartHosted` whose `permissionMode` raises.
    public static let settings = Self(rawValue: "settings")
    /// `POST /v1/hosted/{name}/trust`: trusting a folder grants the agent access, so only the confirm key signs it.
    public static let trust = Self(rawValue: "trust")
    /// `POST /v1/accounts/{id}/use`: switching the Mac-wide login moves every new session, so only the confirm key signs it.
    public static let account = Self(rawValue: "account")
    /// `POST /v1/autopilot`: turning Autopilot on lets the Mac move sessions between accounts, so only the confirm key signs it.
    /// `POST /v1/autopilot/answers` too: the Mac then answers questions and plans by itself.
    public static let autopilot = Self(rawValue: "autopilot")
    /// Everything named by `ConfirmAction`: what a stolen token alone must not be able to do.
    public static let action = Self(rawValue: "action")
    /// `POST /v1/accounts/{id}/priority` and `/auto`, `POST /v1/rotation/swap-at` and `/follow-fable`: what Autopilot may do
    /// with each account decides whose quota running sessions spend, so only the confirm key signs them.
    public static let rotation = Self(rawValue: "rotation")
}

/// The calls signed with `ConfirmPurpose.action`. The subject is `<action>:<target>:<digest of the decoded body>`.
public enum ConfirmAction: String, Sendable, CaseIterable {
    case reply, restart, `continue`, quit, quitIdle, endHosted, stopServer, compact, review, preview
    case macSettings, archive, restore, removeWorktree, moveNow, rekey
}

/// What each signed call must prove, read the same way on the Mac (which enforces it) and the phone (which picks the
/// key to sign with). Permissive sessions and shell escapes take Face ID; a mode that can't be read counts as permissive.
public enum ConfirmPolicy {
    public static func session(mode: PermissionMode?) -> ConfirmLevel { mode.map(\.raises) ?? true ? .biometric : .unlock }

    /// `!` at the start of a prompt is Claude Code's shell mode.
    public static func runsShell(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("!") }

    public static func reply(_ reply: RemoteReply, sessionMode: PermissionMode?) -> ConfirmLevel {
        reply.mode == .keys || runsShell(reply.text) ? .biometric : session(mode: sessionMode)
    }

    public static func start(_ start: StartHosted) -> ConfirmLevel {
        start.permissionMode?.raises == true || runsShell(start.prompt ?? "") ? .biometric : .unlock
    }
}

/// The string a confirm signs, built here so the Mac and the phone produce the same bytes.
public enum ConfirmMessage {
    public enum Invalid: Error, Equatable { case newline(String), separator(String) }

    /// `sidea-confirm-v1\n<macID>\n<deviceID>\n<purpose>\n<subject>\n<unix seconds>`. No field may hold a newline.
    public static func text(macID: String, deviceID: String, purpose: ConfirmPurpose, subject: String, at: Int) throws -> String {
        for (name, value) in [("macID", macID), ("deviceID", deviceID), ("purpose", purpose.rawValue), ("subject", subject)] where value.contains("\n") {
            throw Invalid.newline(name)
        }
        return ["sidea-confirm-v1", macID, deviceID, purpose.rawValue, subject, String(at)].joined(separator: "\n")
    }

    /// The `.allow` subject, binding exactly what the user saw: `<requestID>:allow`, `<requestID>:always:<suggestionID>`,
    /// `<requestID>:approvePlan:acceptEdits` or `:askEdits`, or `<requestID>:answers:<base64url SHA-256 of the answers
    /// re-encoded as sorted-key JSON>` (the Mac hashes the answers it decoded, never the raw body). Nil for deny and
    /// terminal, which never need a signature.
    public static func subject(requestID: RequestID, answer: RemoteAnswer) throws -> String? {
        guard !requestID.contains(":") else { throw Invalid.separator("requestID") }
        let part: String
        switch answer {
        case .allow: part = "allow"
        case .always(let suggestionID): part = "always:\(suggestionID)"
        case .approvePlan(let acceptEdits): part = acceptEdits ? "approvePlan:acceptEdits" : "approvePlan:askEdits"
        case .answers(let answers): part = "answers:\(digest(try canonicalJSON.encode(answers)))"
        case .deny, .terminal: return nil
        }
        return "\(requestID):\(part)"
    }

    /// The `.allow` subject of an allow that switches mode (`AnswerBody.mode`): `<requestID>:allowMode:<mode>`.
    public static func subject(requestID: RequestID, allowMode mode: PermissionMode) throws -> String {
        guard !requestID.contains(":") else { throw Invalid.separator("requestID") }
        guard !mode.rawValue.contains("\n") else { throw Invalid.newline("mode") }
        return "\(requestID):allowMode:\(mode.rawValue)"
    }

    /// The `.trust` subject, `<name>:<base64url SHA-256 of the HostedSession's cwd>`: the folder the user saw.
    public static func subject(trust name: String, cwd: String) throws -> String {
        guard !name.contains(":") else { throw Invalid.separator("name") }
        return "\(name):\(digest(Data(cwd.utf8)))"
    }

    /// The `.account` subject, `<accountID>:use`.
    public static func subject(useAccount id: String) throws -> String {
        guard !id.contains(":") else { throw Invalid.separator("accountID") }
        return "\(id):use"
    }

    /// The `.autopilot` subject, `enabled:true` or `enabled:false`: the state the user chose.
    public static func subject(autopilot change: AutopilotChange) -> String { "enabled:\(change.enabled)" }

    /// The `.autopilot` subject of `POST /v1/autopilot/answers`, `answers:enabled:true` or `answers:enabled:false`, so a
    /// signature for Autopilot itself never turns this on.
    public static func subject(autopilotAnswers change: AutopilotChange) -> String { "answers:enabled:\(change.enabled)" }

    /// The `.rotation` subject of a priority, `<accountID>:priority:<level>`: the account and the level the user chose.
    public static func subject(account id: String, priority: PriorityLevel) throws -> String {
        guard !id.contains(":") else { throw Invalid.separator("accountID") }
        return "\(id):priority:\(priority.rawValue)"
    }

    /// The `.rotation` subject of an account's Auto, `<accountID>:auto:true` or `:auto:false`.
    public static func subject(account id: String, auto enabled: Bool) throws -> String {
        guard !id.contains(":") else { throw Invalid.separator("accountID") }
        return "\(id):auto:\(enabled)"
    }

    /// The `.rotation` subject of the swap threshold, `swapAt:<percent>`.
    public static func subject(swapAt percent: Int) -> String { "swapAt:\(percent)" }

    /// The `.rotation` subject of Follow Fable, `followFable:true` or `followFable:false`.
    public static func subject(followFable enabled: Bool) -> String { "followFable:\(enabled)" }

    /// The `.terminal` subject: the session's terminal name.
    public static func subject(terminal name: String) -> String { name }

    /// The `.keys` subject, `<sessionID>:<base64url SHA-256 of the keys' raw values joined by "\n">`.
    public static func subject(sessionID: SessionKey, keys: [Key]) throws -> String {
        guard !sessionID.contains(":") else { throw Invalid.separator("sessionID") }
        return "\(sessionID):\(digest(Data(keys.map(\.rawValue).joined(separator: "\n").utf8)))"
    }

    /// The `.settings` subject, `<sessionID>:<base64url SHA-256 of the change as sorted-key JSON>` (the Mac hashes the
    /// change it decoded). For a `StartHosted`, `start:<base64url SHA-256 of the StartHosted as sorted-key JSON>`.
    public static func subject(sessionID: SessionKey, settings: SettingsChange) throws -> String {
        guard !sessionID.contains(":") else { throw Invalid.separator("sessionID") }
        return "\(sessionID):\(digest(try canonicalJSON.encode(settings)))"
    }

    public static func subject(start: StartHosted) throws -> String { "start:\(digest(try canonicalJSON.encode(start)))" }

    /// The `.action` subject of a call with a JSON body.
    public static func subject(action: ConfirmAction, target: String = "", body: some Encodable) throws -> String {
        "\(action.rawValue):\(target):\(digest(try canonicalJSON.encode(body)))"
    }

    /// The `.action` subject of a call with no body.
    public static func subject(action: ConfirmAction, target: String = "") -> String {
        "\(action.rawValue):\(target):\(digest(Data()))"
    }

    private static func digest(_ data: Data) -> String { Data(SHA256.hash(data: data)).base64URL }

    private static let canonicalJSON: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

/// A signature from one of the phone's Secure Enclave keys, sent as
/// `X-SideA-Confirm: v1.<unix seconds>.<c|u>.<base64url DER ECDSA-SHA256>`.
public struct ConfirmSignature: Hashable, Sendable {
    public static let header = "X-SideA-Confirm"
    /// The Mac refuses a timestamp further than this from its clock, in seconds.
    public static let window: Double = 120
    /// How long the Mac remembers a signature to refuse it again, in seconds; longer than the window both ways.
    public static let replayMemory: Double = 300

    /// Which of the device's keys signed.
    public enum Signer: String, Hashable, Sendable {
        /// `PairRequest.confirmKey`: usable only after Face ID.
        case confirm = "c"
        /// `PairRequest.unlockKey`: usable while the phone is unlocked.
        case unlock = "u"
    }

    public let at: Int
    public let signer: Signer
    /// DER ECDSA over SHA-256 of the message, as `SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256)` makes it.
    public let signature: Data

    public init(at: Int, signer: Signer, signature: Data) { self.at = at; self.signer = signer; self.signature = signature }

    /// Parses the header value; nil when it isn't `v1.<seconds>.<c|u>.<base64url>`.
    public init?(header value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "v1", let at = Int(parts[1]), let signer = Signer(rawValue: String(parts[2])),
              let signature = Data(base64URL: String(parts[3])), !signature.isEmpty else { return nil }
        self.init(at: at, signer: signer, signature: signature)
    }

    public var headerValue: String { "v1.\(at).\(signer.rawValue).\(signature.base64URL)" }

    /// Checks the signature against the signer's public key (base64url X9.63 P-256) and the Mac's clock;
    /// the Mac still refuses replays.
    public func verify(publicKey: String, macID: String, deviceID: String, purpose: ConfirmPurpose, subject: String, now: Timestamp) -> Bool {
        guard abs(Double(at) - now) <= Self.window, let raw = Data(base64URL: publicKey),
              let key = try? P256.Signing.PublicKey(x963Representation: raw),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              let text = try? ConfirmMessage.text(macID: macID, deviceID: deviceID, purpose: purpose, subject: subject, at: at) else { return false }
        return key.isValidSignature(signature, for: Data(text.utf8))
    }
}

/// `details.level` of `confirm_required` and `confirm_invalid`: which key the Mac wants.
public struct ConfirmLevel: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Sign with the unlock key.
    public static let unlock = Self(rawValue: "unlock")
    /// Sign with the confirm key, after Face ID.
    public static let biometric = Self(rawValue: "biometric")
}

public extension APIError {
    /// The `details` of a `confirm_required` or `confirm_invalid`: the key the Mac wants, and whether only pairing again gives one.
    static func confirmDetails(level: ConfirmLevel, pairAgain: Bool) -> [String: String] {
        var details = [levelDetail: level.rawValue]
        if pairAgain { details[hintDetail] = pairAgainHint }
        return details
    }

    /// Which key a `confirm_required` or `confirm_invalid` asks for.
    var confirmLevel: ConfirmLevel? { details?[Self.levelDetail].map(ConfirmLevel.init(rawValue:)) }
    /// The device has no confirm keys: only pairing again gives it some.
    var pairAgain: Bool { details?[Self.hintDetail] == Self.pairAgainHint }

    private static let levelDetail = "level"
    private static let hintDetail = "hint"
    private static let pairAgainHint = "pairAgain"
}
