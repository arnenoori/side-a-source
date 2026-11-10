import Foundation
import Observation

/// Whether Side A's security key signs, asked once a launch before anything listens. TLS signs with it in every
/// handshake, and a key macOS wants to ask about would hang each one silently, so the server waits for this.
@MainActor @Observable
final class KeyCheck {
    enum State: Equatable {
        case unchecked, checking
        /// Past five seconds: macOS is holding the key, likely behind a dialog.
        case waiting
        case signed, refused
        /// The identity couldn't be read at all.
        case unreadable
    }

    static let waitingText = "Side A is waiting for macOS to let it use its security key. Look for a keychain dialog."
    static let refusedText = "Side A can't use its security key. Make New Key… replaces it, and every iPhone pairs again."
    static let unreadableText = "Side A can't read its security key."

    private(set) var state = State.unchecked
    /// Tests stand in for a signature that takes its time.
    @ObservationIgnored var signs: @Sendable (RemoteKeychain.Identity) -> Bool = { RemoteKeychain.signs($0) }
    /// The one signature under way. `reset` clears it, so an old key's answer finds it gone.
    @ObservationIgnored private var run: UUID?
    @ObservationIgnored private var waited: Task<Void, Never>?

    /// What the Remote tab says while the key holds Remote back.
    var problem: String? {
        switch state {
        case .waiting: Self.waitingText
        case .refused: Self.refusedText
        case .unreadable: Self.unreadableText
        case .unchecked, .checking, .signed: nil
        }
    }

    /// One signature off the main thread; `signed` runs once it has signed. Past five seconds the state says what it
    /// waits for.
    func check(_ identity: RemoteKeychain.Identity, signed: @escaping @MainActor () -> Void) {
        guard run == nil, state != .signed else { return }
        let id = UUID()
        run = id
        state = .checking
        waited = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, run == id else { return }
            state = .waiting
            RemoteLog.shared("still waiting for the security key after 5 s: macOS is holding it")
        }
        let sign = signs
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = Date()
            let signs = sign(identity)
            RemoteLog.shared("security key \(signs ? "signed" : "couldn't sign") in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            DispatchQueue.main.async {
                guard let self, self.run == id else { return }
                self.waited?.cancel()
                self.run = nil
                self.state = signs ? .signed : .refused
                if signs { signed() }
            }
        }
    }

    func unreadable() { state = .unreadable }

    /// A new key: checked again from the start.
    func reset() {
        waited?.cancel()
        waited = nil
        run = nil
        state = .unchecked
    }
}
