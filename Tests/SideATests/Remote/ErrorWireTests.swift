import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

private func answer(_ status: Int, _ code: String, _ message: String, details: [String: String]? = nil, retryAfter: Int? = nil) -> HTTPResponse {
    RemoteServer.error(status, ErrorCode(rawValue: code), message, details: details, retryAfter: retryAfter)
}

private func text(_ response: HTTPResponse) -> String { String(decoding: response.body, as: UTF8.self) }

@Test func anErrorAnswerIsTheSameBytesOnTheWire() {
    var response = answer(404, "session_not_found", "Gone.")
    #expect(response.status == 404 && text(response) == #"{"error":{"code":"session_not_found","message":"Gone.","retryable":false}}"#)
    response = answer(409, "cannot_deliver", "No.", details: ["hint": "tryAgain"])
    #expect(response.status == 409 && text(response) == #"{"error":{"code":"cannot_deliver","details":{"hint":"tryAgain"},"message":"No.","retryable":false}}"#)
    response = answer(429, "rate_limited", "Slow down.", retryAfter: 3)
    #expect(text(response) == #"{"error":{"code":"rate_limited","message":"Slow down.","retryable":true}}"# && response.headers["Retry-After"] == "3")
    response = answer(503, "not_ready", "Starting.", retryAfter: 2)
    #expect(text(response) == #"{"error":{"code":"not_ready","message":"Starting.","retryable":true}}"# && response.headers["Retry-After"] == "2")
    response = answer(409, "in_progress", "Working.")
    #expect(text(response) == #"{"error":{"code":"in_progress","message":"Working.","retryable":true}}"# && response.headers["Retry-After"] == nil)
    response = answer(500, "internal", "Broke.")
    #expect(text(response) == #"{"error":{"code":"internal","message":"Broke.","retryable":false}}"#)
}

@Test func everyCodeTheMacSendsReadsBackAsTheProtocolsError() throws {
    let codes = ["bad_request", "bad_json", "missing_idempotency_key", "unauthorized", "bad_code", "confirm_required", "confirm_invalid", "declined",
                 "sas_mismatch", "forbidden_origin", "not_found", "session_not_found", "request_not_found", "image_not_found", "no_pairing",
                 "confirm_timeout", "already_resolved", "session_waiting", "cannot_deliver", "not_hosted", "turn_changed", "code_busy",
                 "outcome_unknown", "request_pending", "gate_changed", "cursor_expired", "code_expired", "bad_host", "too_large", "unsupported_media",
                 "invalid_answer", "idempotency_mismatch", "invalid_reply", "upgrade_client", "upgrade_mac", "rate_limited", "remote_off", "not_ready",
                 "tmux_missing", "port_not_found", "worktree_kept", "nothing_to_move", "internal", "invalid_option", "invalid_settings", "invalid_review",
                 "uploads_full", "relay_unavailable", "preview_unreachable", "preview_too_large", "not_resumed", "turn_not_found", "unsupported"]
    for code in codes {
        let body = try JSONDecoder().decode(ErrorBody.self, from: answer(422, code, "Words.").body)
        #expect(body.error.code.rawValue == code && body.error.message == "Words." && body.error.retryable == false)
    }
}

@MainActor @Test func aCommandsFailureAnswersWithItsStatusCodeAndWords() throws {
    func wire(_ failure: SessionCommands.Failure) -> (Int, String, String?) {
        let response = RemoteRoutes.response(failure)
        return (response.status, text(response), response.headers["Retry-After"])
    }
    #expect(wire(.noSession) == (404, #"{"error":{"code":"session_not_found","message":"That session isn't running on the Mac any more.","retryable":false}}"#, nil))
    #expect(wire(.notReady) == (503, #"{"error":{"code":"not_ready","message":"Side A is still starting Remote.","retryable":true}}"#, "2"))
    #expect(wire(.invalid("Too long.", "too_long")) == (422, #"{"error":{"code":"invalid_reply","details":{"reason":"too_long"},"message":"Too long.","retryable":false}}"#, nil))
    #expect(wire(.codex(.unsupported)) == (409, #"{"error":{"code":"unsupported","message":"This version of Codex can't change settings from Side A.","retryable":false}}"#, nil))
    #expect(wire(.codex(.invalid("Nope."))) == (422, #"{"error":{"code":"invalid_settings","message":"Nope.","retryable":false}}"#, nil))
}
