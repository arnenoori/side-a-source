import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

/// Every hosted failure and what it answers: the phone's status, code, hint and words, and the Sessions window's words.
@MainActor @Test func everyHostedFailureAnswersWithItsStatusCodeHintAndWords() throws {
    let live = try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: ["pid": 7, "id": "s", "status": "idle", "cwd": "/tmp", "started": 1, "agent": "claude"]))
    struct Row {
        let error: HostedError, status: Int, code: ErrorCode, message: String, details: [String: String]?, retryAfter: Int?
    }
    let rows = [
        Row(error: .unavailable, status: 503, code: .tmuxMissing, message: "Hosted sessions need tmux 3.4 or later (brew install tmux).", details: nil, retryAfter: 60),
        Row(error: .sessionWaiting, status: 409, code: .sessionWaiting, message: "A question is open in that session; answer it first.", details: nil, retryAfter: nil),
        Row(error: .notHosted, status: 409, code: .notHosted, message: "That session isn't hosted by Side A.", details: nil, retryAfter: nil),
        Row(error: .composerBusy, status: 409, code: .cannotDeliver, message: "Something is already typed in that session's prompt.", details: ["hint": "composerBusy"], retryAfter: nil),
        Row(error: .alreadyLive(live), status: 409, code: .cannotDeliver, message: "That session is already running.", details: ["hint": "alreadyLive"], retryAfter: nil),
        Row(error: .refused("No."), status: 409, code: .cannotDeliver, message: "No.", details: nil, retryAfter: nil),
        Row(error: .failed("Broke."), status: 500, code: .internalError, message: "Broke.", details: nil, retryAfter: nil),
        Row(error: .notResumed(name: "sa-app-1", command: "claude --resume s"), status: 502, code: .notResumed,
            message: "It ended on the Mac but didn't start again here. Try again, or run claude --resume s on the Mac.",
            details: ["hosted": "sa-app-1", "command": "claude --resume s", "hint": "tryAgain"], retryAfter: nil),
    ]
    for row in rows {
        let failure = SessionCommands.Failure.hosted(row.error)
        #expect(failure.status == row.status && failure.code == row.code && failure.message == row.message
                && failure.details == row.details && failure.retryAfter == row.retryAfter, "\(row.error)")
        // The Sessions window says the same words, except where the phone's own advice doesn't fit.
        #expect(failure.macMessage == row.message, "\(row.error)")
        // And the route answers with the same, as bytes.
        let response = RemoteRoutes.hostedError(row.error)
        let body = try JSONDecoder().decode(ErrorBody.self, from: response.body)
        #expect(response.status == row.status && body.error.code == row.code && body.error.message == row.message && body.error.details == row.details, "\(row.error)")
        #expect(response.headers["Retry-After"] == row.retryAfter.map(String.init), "\(row.error)")
    }
}
