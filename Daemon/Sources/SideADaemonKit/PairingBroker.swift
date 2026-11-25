#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
import Foundation
import SideACore
import SideAProtocol

/// One pairing, as the Mac's `PairingSession` runs it behind its sheet, here for a terminal: a code that lasts five
/// minutes and is replaced up to six times, one attempt at a time, the comparison digits shown to the person at the
/// machine, who answers Pair or Cancel. `sidead pair` is the sheet: it opens a session, shows the code, and relays the
/// person's answer. The wire half (what a phone sends and is answered) is `docs/remote/protocol.md`, Pairing.
public actor PairingBroker {
    public static let renewals = 6
    public static let confirmTime: TimeInterval = 60

    public struct Attempt: Sendable, Equatable {
        public let id: String
        public let nonce: Data
        public let request: PairRequest
        public let comparison: String
        public let keyMatches: Bool
        public let at: Date
        public static func == (a: Attempt, b: Attempt) -> Bool { a.id == b.id }
    }

    public enum Phase: Sendable, Equatable {
        case code(display: String, expiresAt: TimeInterval)
        case confirm(Attempt)
        case pairing(Attempt)
        case paired(String)
        case stopped(Stop)
    }

    public enum Stop: String, Sendable {
        case expired = "The code expired."
        case wrongCodes = "Too many wrong codes."
        case twoDevices = "Two devices used this code."
        case mismatch = "The codes didn't match."
        case timeout = "Nobody confirmed in time."
        case cancelled = "Pairing was cancelled."
        case unsaved = "The iPhone couldn't be saved."
    }

    public enum Decision: Sendable { case pair, cancel, mismatch, timeout }

    public enum Refusal: Error, Equatable, Sendable { case wrong(triesLeft: Int), expired, busy, closed }

    private var code: PairingCode?
    public private(set) var phase: Phase?
    private var renewed = 0
    private var macKeys: [String: Curve25519.KeyAgreement.PrivateKey] = [:]
    private var waiters: [String: [CheckedContinuation<Decision, Never>]] = [:]
    private var decided: [String: Decision] = [:]
    private var approved: [String: (attempt: Attempt, key: PushKey?)] = [:]
    private var watchers: [UUID: AsyncStream<Phase>.Continuation] = [:]
    public let installID: String?

    public init(installID: String? = nil) { self.installID = installID }

    public var isOpen: Bool { code != nil }

    /// The text for the QR code is built by the caller from `display`; the broker never knows the host's addresses.
    public var currentCode: String? { code?.code }

    public func open(now: Date = Date()) {
        close()
        code = PairingCode.make(now: now.timeIntervalSince1970)
        renewed = 0
        publish(.code(display: code?.display ?? "", expiresAt: code?.expiresAt ?? 0))
    }

    public func close() {
        for (id, list) in waiters { decided[id] = .cancel; for waiter in list { waiter.resume(returning: .cancel) } }
        waiters = [:]
        macKeys = [:]
        code?.finish()
        code = nil
        phase = nil
    }

    /// Phases as they happen, starting with the current one. Ends when the watcher stops listening.
    public func updates() -> AsyncStream<Phase> {
        let id = UUID()
        return AsyncStream { continuation in
            if let phase { continuation.yield(phase) }
            watchers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.unwatch(id) } }
        }
    }

    private func unwatch(_ id: UUID) { watchers[id] = nil }

    private func publish(_ next: Phase) {
        phase = next
        for watcher in watchers.values { watcher.yield(next) }
    }

    public func tick(now: Date = Date()) {
        if case .confirm(let attempt) = phase, now.timeIntervalSince(attempt.at) >= Self.confirmTime {
            decide(.timeout)
            return
        }
        guard case .code = phase, let current = code, now.timeIntervalSince1970 >= current.expiresAt else { return }
        guard renewed < Self.renewals else { publish(.stopped(.expired)); return }
        renewed += 1
        code = PairingCode.make(now: now.timeIntervalSince1970)
        publish(.code(display: code?.display ?? "", expiresAt: code?.expiresAt ?? 0))
    }

    public func submit(_ request: PairRequest, spki: Data, source: String, now: Date = Date()) -> Result<PairPending, Refusal> {
        guard var current = code else { return .failure(.closed) }
        defer { code = current }
        switch current.submit(request.code, now: now.timeIntervalSince1970, source: source) {
        case .wrong(let left):
            return .failure(.wrong(triesLeft: left))
        case .expired:
            if case .code = phase, current.burned { publish(.stopped(.wrongCodes)) }
            return .failure(.expired)
        case .busy:
            if case .confirm(let first) = phase { finish(first.id, .cancel) }
            publish(.stopped(.twoDevices))
            return .failure(.busy)
        case .accepted(let id):
            let key = Curve25519.KeyAgreement.PrivateKey()
            let nonce = Data(Secret.bytes(16))
            let seen = Secret.base64url(request.serverKeyHash) ?? Data()
            // Both sides hash the code exactly as the phone sent it, so they agree however it was typed.
            let digits = (try? PairingTranscript.comparisonCode(code: request.code, nonce: nonce.base64URL,
                                                                macPublicKey: key.publicKey.rawRepresentation.base64URL,
                                                                devicePublicKey: request.devicePublicKey, serverKeyHash: spki.base64URL,
                                                                confirmKey: request.confirmKey, unlockKey: request.unlockKey))
                .map(PairingTranscript.display) ?? "--- ---"
            macKeys[id] = key
            publish(.confirm(Attempt(id: id, nonce: nonce, request: request, comparison: digits, keyMatches: Secret.equal(seen, spki), at: now)))
            return .success(PairPending(attemptID: id, nonce: Secret.base64url(nonce), macPublicKey: Secret.base64url(key.publicKey.rawRepresentation),
                                        expiresAt: now.addingTimeInterval(Self.confirmTime).timeIntervalSince1970))
        }
    }

    public var attempt: Attempt? { if case .confirm(let attempt) = phase { attempt } else { nil } }

    public func knows(_ attemptID: String) -> Bool { macKeys[attemptID] != nil || decided[attemptID] != nil }

    public func wait(_ attemptID: String) async -> Decision {
        if let done = decided[attemptID] { return done }
        if let attempt, attempt.id == attemptID, !attempt.keyMatches { return .mismatch }
        return await withCheckedContinuation { waiters[attemptID, default: []].append($0) }
    }

    /// The phone's Cancel: the comparison goes and a new code takes its place. Anything else is ignored, so the answer
    /// never says whether an attempt exists.
    public func cancel(_ attemptID: String, now: Date = Date()) {
        guard let attempt, attempt.id == attemptID else { return }
        finish(attempt.id, .cancel)
        code?.finish()
        code = PairingCode.make(now: now.timeIntervalSince1970)
        publish(.code(display: code?.display ?? "", expiresAt: code?.expiresAt ?? 0))
    }

    public func takeApproved(_ attemptID: String) -> (attempt: Attempt, key: PushKey?)? { approved.removeValue(forKey: attemptID) }

    private func pushKey(_ attempt: Attempt) -> PushKey? {
        guard let installID, let key = macKeys[attempt.id], let raw = Secret.base64url(attempt.request.devicePublicKey),
              let phone = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else { return nil }
        return try? PushKey.derive(key, peer: phone, macPublicKey: key.publicKey.rawRepresentation, devicePublicKey: raw,
                                   installID: installID, deviceID: attempt.request.deviceID)
    }

    /// The person at the machine answered. Pair is refused when the phone saw another TLS key than this daemon's.
    public func decide(_ decision: Decision) {
        guard let attempt, decision != .pair || attempt.keyMatches else { return }
        if decision == .pair { approved[attempt.id] = (attempt, pushKey(attempt)) }
        finish(attempt.id, decision)
        code?.finish()
        publish(decision == .pair ? .pairing(attempt)
                : .stopped(decision == .mismatch ? .mismatch : decision == .timeout ? .timeout : .cancelled))
    }

    public func finished(_ attemptID: String, saved: Bool) {
        guard case .pairing(let attempt) = phase, attempt.id == attemptID else { return }
        publish(saved ? .paired(attempt.request.device.name) : .stopped(.unsaved))
    }

    private func finish(_ id: String, _ decision: Decision) {
        decided[id] = decision
        macKeys[id] = nil
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume(returning: decision) }
    }
}
