import Foundation

/// protocol's delivery table: what a reply from the phone does, by the session's state. Rows are checked top to bottom,
/// exactly as the table lists them; the app only carries out the decision.
public enum RemoteDelivery {
    public enum State: Sendable, Equatable {
        /// An open request.
        case waiting
        case unknown
        case working
        /// Finished, with the Stop hook waiting for a follow-up.
        case finishedWaiting
        /// Idle, or finished with no waiter.
        case idle
    }

    public enum Decision: Sendable, Equatable {
        /// Pasted into the hosted pane.
        case typed
        /// Handed to the waiting Stop hook.
        case followUp
        /// Delivered through the Stop waiter when the turn ends.
        case queued
        /// Left as mail.
        case note
        /// Keys sent to the hosted pane.
        case keys
        case refused(Refusal)
    }

    public struct Refusal: Sendable, Equatable {
        public let code: String
        public let hint: String?
        public static let waiting = Refusal(code: "session_waiting", hint: nil)
        public static let cannot = Refusal(code: "cannot_deliver", hint: nil)
        public static let notHosted = Refusal(code: "not_hosted", hint: nil)
        public static let continueOnPhone = Refusal(code: "cannot_deliver", hint: "continueOnPhone")
        /// Five follow-ups are already queued.
        public static let queueFull = Refusal(code: "cannot_deliver", hint: "queueFull")
        /// The hooks this delivery goes through are off.
        public static let setup = Refusal(code: "cannot_deliver", hint: "setup")
    }

    /// `mailHooks`: the agent's PreToolUse/PostToolUse mail hooks are installed. `stopHooks`: the session's Stop hook can take a
    /// queued follow-up. Only Claude's Stop hook waits for one: Codex's tells the island and exits, so nothing queued for it
    /// would ever go, and it is refused here. (Codex through its app server has its own queue, before this table.)
    public static func decide(_ state: State, hosted: Bool, agent: AgentProvider, mode: ReplyMode,
                              mailHooks: Bool, stopHooks: Bool) -> Decision {
        let claude = agent == .claude
        let note: Decision = mailHooks ? .note : .refused(claude ? .setup : .cannot)
        let queued: Decision = !claude ? .refused(.cannot) : stopHooks ? .queued : .refused(.setup)
        let keys: Decision = hosted ? .keys : .refused(.notHosted)
        switch state {
        case .waiting:
            switch mode {
            case .auto, .followUp: return .refused(.waiting)
            case .note: return note
            case .keys: return keys
            }
        case .unknown:
            return mode == .keys ? keys : .refused(.cannot)
        case .working where hosted:
            switch mode {
            // Claude Code queues a message submitted mid-turn; Codex is refused until hosting's open question 7 is settled.
            case .auto: return claude ? .typed : queued
            case .followUp: return queued
            case .note: return note
            case .keys: return .keys
            }
        case .working:
            switch mode {
            case .auto: return claude ? note : queued
            case .followUp: return queued
            case .note: return note
            case .keys: return .refused(.notHosted)
            }
        case .finishedWaiting:
            switch mode {
            case .auto, .followUp: return .followUp
            case .note: return .refused(.cannot)
            case .keys: return keys
            }
        case .idle:
            if mode == .keys { return keys }
            return hosted ? (mode == .note ? .refused(.cannot) : .typed) : .refused(.continueOnPhone)
        }
    }
}
