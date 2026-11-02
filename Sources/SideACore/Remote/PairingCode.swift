import CryptoKit
import Foundation

/// The 8-character code a pairing sheet shows: five minutes, single use, one attempt at a time. Wrong tries count per
/// source address, five each, and twenty in all void the code: one address guessing can't end the user's pairing.
public struct PairingCode: Sendable {
    /// Crockford base32: no I, L, O or U, so a misread letter decodes to the digit it looks like.
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let lifetime: TimeInterval = 300
    public static let tries = 5
    public static let totalTries = 20

    public let code: String
    public let expiresAt: TimeInterval
    private var wrong: [String: Int] = [:]
    private var wrongInAll = 0
    public private(set) var state: State = .open

    public enum State: Sendable, Equatable {
        case open
        /// A right code: this attempt waits for the Mac's Pair.
        case pending(attempt: String)
        /// Used, burned by wrong tries, raced, or expired. A new code is needed.
        case void
    }

    public enum Outcome: Sendable, Equatable {
        /// 202: the attempt to show on the Mac.
        case accepted(attempt: String)
        /// 401 `bad_code`.
        case wrong(triesLeft: Int)
        /// 410 `code_expired`: expired, burned by the fifth wrong try, or already used.
        case expired
        /// 409 `code_busy`: a second right code while one attempt waits voids both, so a race is never silently won.
        case busy
    }

    public init(code: String, now: TimeInterval) {
        self.code = code
        expiresAt = now + Self.lifetime
    }

    public static func make(now: TimeInterval, random: (Int) -> [UInt8] = Secret.bytes) -> PairingCode {
        // 32 divides 256, so taking each byte mod 32 has no bias.
        PairingCode(code: String(random(8).map { alphabet[Int($0) % 32] }), now: now)
    }

    /// `K7Q2-9XMD`
    public var display: String { "\(code.prefix(4))-\(code.dropFirst(4))" }

    /// Case, dashes and spaces ignored; O reads as 0, I and L as 1.
    public static func normalize(_ input: String) -> String {
        String(input.uppercased().compactMap { c -> Character? in
            switch c {
            case "-", " ": nil
            case "O": "0"
            case "I", "L": "1"
            default: c
            }
        })
    }

    /// What `source` has left; the address that used up its five gets nothing more from this code, right or wrong.
    public func triesLeft(_ source: String = "") -> Int { max(0, Self.tries - wrong[source, default: 0]) }

    /// Whether wrong tries, from every address together, voided the code.
    public var burned: Bool { wrongInAll >= Self.totalTries }

    public mutating func submit(_ input: String, now: TimeInterval, source: String = "",
                                attempt: () -> String = { UUID().uuidString.lowercased() }) -> Outcome {
        guard state != .void, now < expiresAt else { state = .void; return .expired }
        guard triesLeft(source) > 0 else { return .expired }
        guard Secret.equal(Data(Self.normalize(input).utf8), Data(code.utf8)) else {
            wrong[source, default: 0] += 1
            wrongInAll += 1
            if burned { state = .void; return .expired }
            return triesLeft(source) > 0 ? .wrong(triesLeft: triesLeft(source)) : .expired
        }
        if case .pending = state { state = .void; return .busy }
        let id = attempt()
        state = .pending(attempt: id)
        return .accepted(attempt: id)
    }

    /// Pair, Cancel and a timeout all end the code: it is single use.
    public mutating func finish() { state = .void }
}

/// Device tokens: `sa1_` and 32 random bytes. The Mac keeps only their SHA-256.
public enum DeviceToken {
    public static let prefix = "sa1_"

    public static func make() -> String { prefix + Secret.base64url(Data(Secret.bytes(32))) }

    public static func hash(_ token: String) -> Data { Data(SHA256.hash(data: Data(token.utf8))) }

    /// The index of the matching hash. Every hash is compared in full, so the time taken says nothing about which.
    public static func match(_ token: String, in hashes: [Data]) -> Int? {
        let presented = hash(token)
        var found: Int?
        for (index, stored) in hashes.enumerated() where Secret.equal(presented, stored) && found == nil { found = index }
        return found
    }
}

public enum Secret {
    public static func bytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess, "The system random generator failed.")
        return bytes
    }

    /// Constant time for equal lengths.
    public static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func base64url(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !base64.contains("=") else { return nil }
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
