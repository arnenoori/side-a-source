import ActivityKit
import AppIntents
import Foundation
import SideAProtocol
import SideARemoteShared

// The Live Activity's buttons (section 5.4). Compiled into the app and the widgets; a
// LiveActivityIntent runs in the app's process, which holds the token and the outbox.

/// Deny never needs unlock: it can only stop something.
struct DenyRequestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Deny"
    static let isDiscoverable = false

    @Parameter(title: "Request") var requestID: String
    @Parameter(title: "Mac") var macID: String

    init() {}
    init(requestID: String, macID: String) { self.requestID = requestID; self.macID = macID }

    func perform() async throws -> some IntentResult {
        let result = await NotificationAnswer.send(.deny(message: nil), to: requestID, macID: macID)
        if result.settles { await LiveActivityAnswer.settle(requestID) }
        return .result()
    }
}

/// Allow for a request the Mac marked `lockScreen`: runs without unlocking.
struct AllowSafeRequestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Allow"
    static let isDiscoverable = false

    @Parameter(title: "Request") var requestID: String
    @Parameter(title: "Mac") var macID: String

    init() {}
    init(requestID: String, macID: String) { self.requestID = requestID; self.macID = macID }

    func perform() async throws -> some IntentResult {
        // The activity's state comes from an unsealed push; only the sealed payload this phone opened can say
        // the request may be allowed without unlocking.
        guard let payload = await PushOpener.cached(requestID), payload.mac == macID, PushOpener.allowsLocked(payload) else {
            RemoteLog.error(.push, "Lock Screen allow refused for \(requestID): no verified payload")
            return .result()
        }
        let result = await NotificationAnswer.send(.allow(confirmDestructive: false), to: requestID, macID: macID)
        if result.settles { await LiveActivityAnswer.settle(requestID) }
        return .result()
    }
}

/// Allow for an `unlock` request: iOS asks for Face ID or the passcode first.
struct AnswerRequestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Allow"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Request") var requestID: String
    @Parameter(title: "Mac") var macID: String

    init() {}
    init(requestID: String, macID: String) { self.requestID = requestID; self.macID = macID }

    func perform() async throws -> some IntentResult {
        let result = await NotificationAnswer.send(.allow(confirmDestructive: false), to: requestID, macID: macID)
        if result.settles { await LiveActivityAnswer.settle(requestID) }
        return .result()
    }
}

enum LiveActivityAnswer {
    /// The answered request leaves the activity at once; the Mac's next push confirms the counts.
    static func settle(_ requestID: String) async {
        for activity in Activity<MacActivityAttributes>.activities where activity.content.state.topRequest == requestID {
            var state = activity.content.state
            state.waiting = max(0, state.waiting - 1)
            state.topRequest = nil
            await activity.update(ActivityContent(state: state, staleDate: activity.content.staleDate))
        }
        DeliveredRequests.clear([requestID])
    }
}
