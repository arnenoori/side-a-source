import Foundation
import SideAProtocol

/// A model of the other agent picked for a session: nothing reaches the Mac until Send hands the session off.
public struct HandoffDraft: Equatable, Sendable {
    public var agent: AgentProvider
    public var modelID: String?
    public var effort: Effort?
    public var accountID: String?
    /// The Mac's draft as Review showed and edited it; nil sends the Mac's own, fetched at Send.
    public var handoff: Handoff?

    public init(agent: AgentProvider, modelID: String? = nil, effort: Effort? = nil, accountID: String? = nil, handoff: Handoff? = nil) {
        self.agent = agent; self.modelID = modelID; self.effort = effort; self.accountID = accountID; self.handoff = handoff
    }
}

/// What a handoff's `SendKey` was sent with.
public struct HandoffAttempt: Equatable, Sendable {
    public let draft: HandoffDraft
    public let message: String
    /// The photos that go with it: a different set is a different request.
    public let photos: [String]
    public init(draft: HandoffDraft, message: String, photos: [String] = []) { self.draft = draft; self.message = message; self.photos = photos }
}

/// A session's handoff to the other agent on the phone, from the pick until the new session shows. No stage: none picked.
public enum HandoffStage: Equatable, Sendable {
    case drafted(HandoffDraft)
    case sending(HandoffDraft, message: String)
    /// Started as `name`, which hasn't shown yet: should it end first, the words and the draft come back.
    case handedOff(HandoffDraft, message: String, name: String)

    public enum Event: Equatable, Sendable {
        /// Settings picked the other agent's model; a review already kept stays with it.
        case picked(HandoffDraft)
        case reviewed(Handoff)
        case send(message: String)
        case started(name: String)
        /// Refused, or not known to have reached the Mac: the words are still in the field.
        case notStarted
        /// Keep the session's own agent, or a change for it in Settings.
        case dropped
        /// The session's row went.
        case sessionGone
        /// The new session is listed.
        case arrived(name: String)
        /// The new session ended before it started.
        case ended(name: String)
    }

    public var draft: HandoffDraft {
        switch self {
        case .drafted(let draft), .sending(let draft, _), .handedOff(let draft, _, _): draft
        }
    }

    /// What Send hands off from the field: none once it has gone.
    public var pending: HandoffDraft? { if case .handedOff = self { nil } else { draft } }

    /// `giveBack`: the words for the field.
    public static func next(_ stage: Self?, _ event: Event) -> (stage: Self?, giveBack: String?) {
        if case .handedOff(let draft, let message, let name)? = stage {
            switch event {
            case .arrived(name): return (nil, nil)
            case .ended(name): return (.drafted(draft), message)
            case .picked(let draft): return (.drafted(draft), nil)
            case .dropped: return (nil, nil)
            // The row goes as the Mac ends it for the new one.
            case .reviewed, .send, .started, .notStarted, .sessionGone, .arrived, .ended: return (stage, nil)
            }
        }
        return (step(stage, event), nil)
    }

    private static func step(_ stage: Self?, _ event: Event) -> Self? {
        switch (stage, event) {
        case (nil, .picked(let draft)): return .drafted(draft)
        case (.drafted(let old)?, .picked(var draft)):
            draft.handoff = old.handoff
            return .drafted(draft)
        case (.sending(let old, let message)?, .picked(var draft)):
            draft.handoff = old.handoff
            return .sending(draft, message: message)
        case (.drafted(var draft)?, .reviewed(let handoff)):
            draft.handoff = handoff
            return .drafted(draft)
        case (.sending(var draft, let message)?, .reviewed(let handoff)):
            draft.handoff = handoff
            return .sending(draft, message: message)
        case (.drafted(let draft)?, .send(let message)): return .sending(draft, message: message)
        case (.sending(let draft, let message)?, .started(let name)): return .handedOff(draft, message: message, name: name)
        case (.sending(let draft, _)?, .notStarted): return .drafted(draft)
        case (_, .dropped): return nil
        case (.drafted?, .sessionGone): return nil
        // The row goes as the Mac ends it for the new one.
        case (.sending?, .sessionGone): return stage
        case (nil, _), (.drafted?, .started), (.drafted?, .notStarted), (.sending?, .send), (_, .arrived), (_, .ended), (.handedOff?, _): return stage
        }
    }
}
