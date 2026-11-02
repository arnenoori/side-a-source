import CryptoKit
import Foundation
import SideAProtocol

/// What a phone proves when it acts: nothing (a locked phone, a notification action), that it was unlocked (its
/// Secure Enclave key usable only then), or that its owner just passed Face ID (its key bound to biometry). The Mac
/// decides what each action needs from its own view of the request, never the phone's.
public enum ConfirmProof: Int, Comparable, Sendable {
    case none, unlock, biometric

    public static func < (a: ConfirmProof, b: ConfirmProof) -> Bool { a.rawValue < b.rawValue }

    public init(_ gate: AllowGate) {
        // A gate this build doesn't know asks the most.
        self = gate == .lockScreen ? .none : gate == .unlock ? .unlock : .biometric
    }

    /// A level this build doesn't know asks the most.
    public init(_ level: ConfirmLevel) { self = level == .unlock ? .unlock : .biometric }

    public var level: ConfirmLevel? { switch self { case .none: nil; case .unlock: .unlock; case .biometric: .biometric } }
}

/// `X-SideA-Confirm` checked against a device's keys (see SideAProtocol's ConfirmSignature), and each signature taken once.
public enum ConfirmGate {
    public enum Failure: String, Error, Sendable, Equatable {
        /// No header, or this device has no key for what was signed.
        case missing
        case malformed, invalid, replayed
    }

    /// The public keys a device registered at pairing: base64url X9.63 P-256.
    public struct Keys: Codable, Sendable, Equatable {
        public var confirm: String?
        public var unlock: String?
        public init(confirm: String?, unlock: String?) { self.confirm = confirm; self.unlock = unlock }
        public var isEmpty: Bool { confirm == nil && unlock == nil }
    }

    public static func verify(_ value: String?, macID: String, deviceID: String, purpose: ConfirmPurpose, subject: String, keys: Keys,
                              replay: ReplayCache, now: Date = Date()) -> Result<ConfirmProof, Failure> {
        guard let value, !value.isEmpty else { return .failure(.missing) }
        guard let signature = ConfirmSignature(header: value) else { return .failure(.malformed) }
        let proof: ConfirmProof = signature.signer == .confirm ? .biometric : .unlock
        guard let key = proof == .biometric ? keys.confirm : keys.unlock else { return .failure(.missing) }
        guard signature.verify(publicKey: key, macID: macID, deviceID: deviceID, purpose: purpose, subject: subject,
                               now: now.timeIntervalSince1970) else { return .failure(.invalid) }
        // Keyed on what was signed and its r, the part of `(r, s)` a copy can't change: ECDSA signatures are malleable, so a
        // captured one can come back with different bytes, but only the key's holder can make another for the same second.
        guard let message = try? ConfirmMessage.text(macID: macID, deviceID: deviceID, purpose: purpose, subject: subject, at: signature.at),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature.signature),
              replay.first([signature.signer.rawValue, message, parsed.rawRepresentation.prefix(32).base64EncodedString()].joined(separator: "\n"), now: now)
        else { return .failure(.replayed) }
        return .success(proof)
    }

    /// Messages seen recently, so one captured header can't be sent twice. In memory: the two-minute window can reopen
    /// across a relaunch of the Mac app, and only for a header captured before it.
    public final class ReplayCache: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String: Date] = [:]

        public init() {}

        func first(_ message: String, now: Date) -> Bool {
            lock.withLock {
                seen = seen.filter { now.timeIntervalSince($0.value) < ConfirmSignature.replayMemory }
                return seen.updateValue(now, forKey: message) == nil
            }
        }
    }
}
