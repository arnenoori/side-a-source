import CoreImage
import CryptoKit
import Foundation
import Observation
import SideACore
import SideAProtocol

/// One open pairing sheet: its code, and the one attempt that may be waiting for the user's click.
@MainActor @Observable
final class PairingSession {
    static let renewals = 6
    static let confirmTime: TimeInterval = 60

    struct Attempt: Equatable {
        let id: String
        let nonce: Data
        let request: PairRequest
        /// The six digits the phone shows too.
        let comparison: String
        /// The phone saw Side A's own key. If not, Pair isn't offered at all.
        let keyMatches: Bool
        let at: Date
        static func == (a: Attempt, b: Attempt) -> Bool { a.id == b.id }
    }

    enum Phase: Equatable {
        case code
        case confirm(Attempt)
        case paired(String)
        /// Too many wrong codes, a raced code, the renewals used up: the sheet's title says which, with Start Again.
        case stopped(String)
    }

    enum Decision: Sendable { case pair, cancel, mismatch, timeout }

    enum Refusal: Error, Equatable {
        case wrong, expired, busy
    }

    private(set) var code: PairingCode
    private(set) var phase: Phase = .code
    private(set) var renewed = 0
    @ObservationIgnored private var macKeys: [String: Curve25519.KeyAgreement.PrivateKey] = [:]
    /// Each open wait with the connection it came on, so a dropped connection can be told apart from a re-poll.
    @ObservationIgnored private var waiters: [String: [(connection: UInt64?, continuation: CheckedContinuation<Decision, Never>)]] = [:]
    @ObservationIgnored private var decided: [String: Decision] = [:]
    @ObservationIgnored private var approved: [String: (attempt: Attempt, key: PushKey?)] = [:]
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// How long a dropped wait has to come back before its attempt is cancelled: long enough for the phone to re-poll.
    @ObservationIgnored var dropGrace: Duration = .seconds(3)
    /// The relay install the push key is bound to; nil leaves the phone without push until it rekeys.
    let installID: String?

    init(now: Date = Date(), installID: String? = nil) {
        self.installID = installID
        code = PairingCode.make(now: now.timeIntervalSince1970)
        startTimer()
        log("code shown")
    }

    /// Never the code, the comparison digits or an attempt id.
    private func log(_ line: String) { RemoteLog.shared("pairing: " + line) }

    private func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    /// A code that expires unused is replaced, up to six times while the sheet stays open.
    func tick(now: Date = Date()) {
        if case .confirm(let attempt) = phase, -attempt.at.timeIntervalSince(now) >= Self.confirmTime {
            decide(.timeout)
            return
        }
        guard phase == .code, now.timeIntervalSince1970 >= code.expiresAt else { return }
        guard renewed < Self.renewals else { phase = .stopped("Code Expired"); log("code expired, renewals used up"); return }
        renewed += 1
        code = PairingCode.make(now: now.timeIntervalSince1970)
        log("code renewed (\(renewed) of \(Self.renewals))")
    }

    /// Whether unused codes still renew on their own.
    var renewing: Bool { timer.map { !$0.isCancelled } ?? false }

    func restart() {
        end()
        code = PairingCode.make(now: Date().timeIntervalSince1970)
        renewed = 0
        phase = .code
        startTimer()
        log("started again, code shown")
    }

    /// `spki` is the Mac's own key hash, to compare with the one the phone saw.
    /// `source` is the address it came from, so one address's wrong tries are its own (PairingCode).
    func submit(_ request: PairRequest, spki: Data, source: String = "", now: Date = Date()) -> Result<PairPending, Refusal> {
        switch code.submit(request.code, now: now.timeIntervalSince1970, source: source) {
        case .wrong(let left):
            log("\(request.device.name) sent a wrong code, \(left) tries left from its address")
            return .failure(.wrong)
        case .expired:
            log("\(request.device.name) sent a code that's expired or used up" + (code.triesLeft(source) == 0 ? " (its address has no tries left)" : ""))
            if phase == .code, code.burned { phase = .stopped("Too Many Wrong Codes") }
            return .failure(.expired)
        case .busy:
            // A second phone with the same code: someone raced the user, so neither attempt goes on.
            if case .confirm(let first) = phase { finish(first.id, .cancel) }
            phase = .stopped("Two Devices Used This Code")
            log("\(request.device.name) used a code another device already used; stopped")
            return .failure(.busy)
        case .accepted(let id):
            let key = Curve25519.KeyAgreement.PrivateKey()
            let nonce = Data(Secret.bytes(16))
            let seen = Secret.base64url(request.serverKeyHash) ?? Data()
            // Both sides hash the code exactly as the phone sent it, so they agree however it was typed.
            let digits = (try? PairingTranscript.comparisonCode(code: request.code, nonce: nonce.base64URL, macPublicKey: key.publicKey.rawRepresentation.base64URL,
                                                                devicePublicKey: request.devicePublicKey, serverKeyHash: spki.base64URL,
                                                                confirmKey: request.confirmKey, unlockKey: request.unlockKey))
                .map(PairingTranscript.display) ?? "––– –––"
            macKeys[id] = key
            phase = .confirm(Attempt(id: id, nonce: nonce, request: request, comparison: digits,
                                     keyMatches: Secret.equal(seen, spki), at: now))
            log("\(request.device.name) (\(request.device.model), app \(request.device.app)) sent the right code; "
                + (Secret.equal(seen, spki) ? "comparing digits on the Mac" : "it saw a different security key, so Pair isn't offered"))
            return .success(PairPending(attemptID: id, nonce: Secret.base64url(nonce), macPublicKey: Secret.base64url(key.publicKey.rawRepresentation),
                                        expiresAt: now.addingTimeInterval(Self.confirmTime).timeIntervalSince1970))
        }
    }

    var attempt: Attempt? { if case .confirm(let attempt) = phase { attempt } else { nil } }

    func knows(_ attemptID: String) -> Bool { macKeys[attemptID] != nil || decided[attemptID] != nil }

    /// The phone's long poll: the user's click, or a timeout 60 s after the attempt began.
    func wait(_ attemptID: String, connection: UInt64? = nil) async -> Decision {
        if let done = decided[attemptID] { return done }
        if let attempt, attempt.id == attemptID, !attempt.keyMatches { return .mismatch }
        log("phone waiting" + (connection.map { " on #\($0)" } ?? ""))
        return await withCheckedContinuation { continuation in waiters[attemptID, default: []].append((connection, continuation)) }
    }

    /// The phone's Cancel: the comparison goes and a new code takes its place. Anything else is ignored, so the answer
    /// never says whether an attempt exists.
    func cancel(_ attemptID: String) {
        guard let attempt, attempt.id == attemptID else { return }
        log("phone cancelled; new code shown")
        finish(attempt.id, .cancel)
        code.finish()
        code = PairingCode.make(now: Date().timeIntervalSince1970)
        phase = .code
    }

    /// A connection closed. Its waits are dropped, and an attempt left with none is cancelled unless the phone polls
    /// again within `dropGrace`: the app was killed, or Cancel didn't reach the Mac.
    func dropped(connection: UInt64) {
        for (id, list) in waiters {
            let gone = list.filter { $0.connection == connection }
            guard !gone.isEmpty else { continue }
            waiters[id] = list.filter { $0.connection != connection }
            gone.forEach { $0.continuation.resume(returning: .cancel) }
            guard waiters[id]?.isEmpty != false, attempt?.id == id else { continue }
            log("phone's wait on #\(connection) dropped; cancelling unless it polls again within \(dropGrace)")
            Task { [weak self] in
                try? await Task.sleep(for: self?.dropGrace ?? .zero)
                guard let self, self.waiters[id]?.isEmpty != false else { return }
                self.log("phone didn't come back")
                self.cancel(id)
            }
        }
    }

    /// The approved attempt and the push key shared with the phone (relay-and-release, Key exchange). Taken once; the
    /// X25519 private key is gone after.
    func takeApproved(_ attemptID: String) -> (attempt: Attempt, key: PushKey?)? { approved.removeValue(forKey: attemptID) }

    private func pushKey(_ attempt: Attempt) -> PushKey? {
        guard let installID, let key = macKeys[attempt.id], let raw = Secret.base64url(attempt.request.devicePublicKey),
              let phone = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else { return nil }
        return try? PushKey.derive(key, peer: phone, macPublicKey: key.publicKey.rawRepresentation, devicePublicKey: raw,
                                   installID: installID, deviceID: attempt.request.deviceID)
    }

    /// Pair, Codes Don't Match or Cancel on the sheet; or the timeout.
    func decide(_ decision: Decision) {
        guard let attempt, decision != .pair || attempt.keyMatches else { return }
        if decision == .pair { approved[attempt.id] = (attempt, pushKey(attempt)) }
        log("\(attempt.request.device.name): " + ["pair": "Pair clicked", "mismatch": "codes didn't match", "timeout": "nobody clicked Pair in time",
                                                    "cancel": "cancelled on the Mac"]["\(decision)", default: "\(decision)"])
        finish(attempt.id, decision)
        code.finish()
        phase = decision == .pair ? .paired(attempt.request.device.name)
            : .stopped(decision == .mismatch ? "Codes Didn’t Match" : decision == .timeout ? "Nobody Clicked Pair in Time" : "Pairing Cancelled")
    }

    private func finish(_ id: String, _ decision: Decision) {
        decided[id] = decision
        macKeys[id] = nil
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.continuation.resume(returning: decision) }
    }

    /// Closing the sheet voids the code and answers anyone still waiting.
    func end() {
        if renewing { log("sheet closed") }
        timer?.cancel()
        if let attempt { finish(attempt.id, .cancel) }
        for (id, list) in waiters { decided[id] = .cancel; list.forEach { $0.continuation.resume(returning: .cancel) } }
        waiters = [:]
        macKeys = [:]
        code.finish()
    }

    /// Everything in the fragment, so no web server ever sees it. The universal link replaces the scheme once the site
    /// serves its association file.
    /// `address` is the primary one (the tailnet's, else the LAN's); `lan` every LAN address, best first.
    /// `relay` adds `i` (install id), `r` (relay origin) and `p` (the sheet's ticket); `address` may then be nil.
    static func link(address: String?, lan: [String], spki: Data, mac: MacInfo, tailnetName: String?, code: String,
                     relay: (url: URL, installID: String, ticket: Data)? = nil) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        func escape(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
        var fields = ["v=2"]
        if let address { fields.append("a=" + escape(address)) }
        if !lan.isEmpty { fields.append("l=" + lan.map(escape).joined(separator: ",")) }
        fields += ["fp=" + Secret.base64url(spki), "n=" + escape(mac.name), "m=" + mac.id]
        if let tailnetName { fields.append("t=" + escape(tailnetName)) }
        if let relay { fields += ["i=" + relay.installID, "r=" + escape(relay.url.absoluteString), "p=" + Secret.base64url(relay.ticket)] }
        fields.append("c=" + code)
        return "sidea-remote://pair#" + fields.joined(separator: "&")
    }

    static func qr(_ text: String, scale: CGFloat = 8, correction: String = "M") -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue(correction, forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return CIContext().createCGImage(image, from: image.extent)
    }
}
