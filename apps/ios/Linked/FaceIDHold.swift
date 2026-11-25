import Foundation

/// The one authenticated context that signs with the Face ID key for as long as the app is in use. Generic over the
/// context and told how to evaluate one, so the hold and expire rules run in tests without biometry.
///
/// It keeps a log line for every reason a prompt appears, since only a device shows whether iOS still honours a held
/// context: the line says what ended the last one (an expiry, or the code of a signature it refused).
nonisolated final class FaceIDHold<Context: AnyObject>: @unchecked Sendable {
    /// LAContext is thread-safe but not marked Sendable.
    struct Evaluated: @unchecked Sendable { let context: Context }

    struct Grant {
        let context: Context
        /// Already authenticated before this call, so using it should not ask.
        let reused: Bool
    }

    private let lock = NSLock()
    private var shared: Context?
    /// The Face ID prompt on screen: a second signature waits for it, since iOS cancels one of two at once.
    private var evaluating: Task<Evaluated?, Never>?
    /// Bumped by `expire`, so an evaluation that finishes after the app left isn't kept.
    private var epoch = 0
    private var ended = "no Face ID yet in this launch"
    private let invalidate: @Sendable (Context) -> Void
    private let log: @Sendable (String) -> Void

    init(invalidate: @escaping @Sendable (Context) -> Void, log: @escaping @Sendable (String) -> Void) {
        self.invalidate = invalidate
        self.log = log
    }

    var held: Bool { lock.withLock { shared != nil } }

    /// The held context, or the result of `evaluate` (which shows the prompt). Nil when the person declined.
    func context(reason: String, evaluate: @escaping @Sendable (String) async -> Evaluated?) async -> Grant? {
        let (reused, pending, started, why) = lock.withLock { () -> (Context?, Task<Evaluated?, Never>?, Int, String?) in
            if let shared { return (shared, nil, epoch, nil) }
            if let evaluating { return (nil, evaluating, epoch, nil) }
            let task = Task<Evaluated?, Never> { await evaluate(reason) }
            evaluating = task
            return (nil, task, epoch, ended)
        }
        if let reused {
            log("Face ID held, reused")
            return Grant(context: reused, reused: true)
        }
        guard let pending else { return nil }
        if let why { log("Face ID asked: \(why) (for \"\(reason)\")") }
        let context = await pending.value?.context
        lock.withLock {
            if evaluating == pending { evaluating = nil }
            guard let context else { return }
            if epoch == started { shared = context } else { ended = "expired while the prompt was up" }
        }
        return context.map { Grant(context: $0, reused: false) }
    }

    /// A signature the held context didn't satisfy: it is dropped, so the next one asks. Not invalidated, as a signature
    /// may still be using it.
    func drop(_ context: Context, code: Int, why: String? = nil) {
        lock.withLock {
            guard shared === context else { return }
            shared = nil
            ended = why ?? "the held Face ID was refused by the key (code \(code))"
        }
    }

    /// Obtains the hold at a moment the person can foresee (the app opening or coming back), so a send never has to.
    /// A held context that `stillGood` no longer vouches for (iOS drops one when the phone locks) is dropped and asked
    /// for again here, not at the next Send. Returns whether a prompt was raised.
    @discardableResult
    func prewarm(reason: String, stillGood: @Sendable (Context) -> Bool, evaluate: @escaping @Sendable (String) async -> Evaluated?) async -> Bool {
        if let current = lock.withLock({ shared }) {
            if stillGood(current) {
                log("Face ID prewarm: already held, no prompt")
                return false
            }
            drop(current, code: 0, why: "the held Face ID no longer signs after the app came back")
        }
        let grant = await context(reason: reason, evaluate: evaluate)
        log(grant == nil ? "Face ID prewarm: declined, a send will ask" : "Face ID prewarm: \(grant?.reused == true ? "joined a prompt" : "asked at foreground")")
        return grant?.reused == false
    }

    /// A context that has already authenticated for the key, such as one a signature's own prompt just passed.
    func adopt(_ context: Context) {
        lock.withLock { shared = context }
    }

    /// The app has been away as long as its lock waits, or was locked.
    func expire(_ cause: String) {
        let old = lock.withLock { () -> Context? in
            defer { shared = nil; epoch += 1; ended = "expired: \(cause)" }
            return shared
        }
        if let old { invalidate(old) }
    }
}
