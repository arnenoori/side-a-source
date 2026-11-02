import Foundation

public struct ErrorCode: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    // 400
    public static let badRequest = Self(rawValue: "bad_request")
    public static let badJSON = Self(rawValue: "bad_json")
    public static let missingIdempotencyKey = Self(rawValue: "missing_idempotency_key")
    // 401
    public static let unauthorized = Self(rawValue: "unauthorized")
    public static let badCode = Self(rawValue: "bad_code")
    /// No `X-SideA-Confirm` where the Mac requires one; `details.level` says which key (`ConfirmLevel`), and
    /// `details.hint` is `pairAgain` when the device has no keys.
    public static let confirmRequired = Self(rawValue: "confirm_required")
    /// The signature doesn't verify, its time is outside ±120 s, it was used before, or it's from the wrong key; details as above.
    public static let confirmInvalid = Self(rawValue: "confirm_invalid")
    // 403
    /// Pairing cancelled on the Mac.
    public static let declined = Self(rawValue: "declined")
    /// Codes Don't Match was clicked on the Mac.
    public static let sasMismatch = Self(rawValue: "sas_mismatch")

    public static let forbiddenOrigin = Self(rawValue: "forbidden_origin")
    // 404
    public static let notFound = Self(rawValue: "not_found")
    public static let sessionNotFound = Self(rawValue: "session_not_found")
    public static let requestNotFound = Self(rawValue: "request_not_found")
    public static let imageNotFound = Self(rawValue: "image_not_found")
    /// No pairing sheet is open on the Mac.
    public static let noPairing = Self(rawValue: "no_pairing")
    // 408
    /// Nobody clicked Pair within 60 s.
    public static let confirmTimeout = Self(rawValue: "confirm_timeout")
    // 409
    public static let alreadyResolved = Self(rawValue: "already_resolved")
    public static let sessionWaiting = Self(rawValue: "session_waiting")
    public static let cannotDeliver = Self(rawValue: "cannot_deliver")
    public static let notHosted = Self(rawValue: "not_hosted")
    public static let inProgress = Self(rawValue: "in_progress")
    /// A follow-up for a finished turn the session has moved past.
    public static let turnChanged = Self(rawValue: "turn_changed")
    /// Two devices used one pairing code; both attempts are void.
    public static let codeBusy = Self(rawValue: "code_busy")
    /// An earlier attempt with this key may or may not have taken effect. Never retried automatically.
    public static let outcomeUnknown = Self(rawValue: "outcome_unknown")
    /// Keys refused while a destructive request is open on the session.
    public static let requestPending = Self(rawValue: "request_pending")
    /// The request's gate rose between showing and answering; fetch it and review again.
    public static let gateChanged = Self(rawValue: "gate_changed")
    // 410
    public static let cursorExpired = Self(rawValue: "cursor_expired")
    public static let codeExpired = Self(rawValue: "code_expired")
    // 421
    public static let badHost = Self(rawValue: "bad_host")
    // 413, 415
    public static let tooLarge = Self(rawValue: "too_large")
    public static let unsupportedMedia = Self(rawValue: "unsupported_media")
    // 422
    public static let invalidAnswer = Self(rawValue: "invalid_answer")
    public static let idempotencyMismatch = Self(rawValue: "idempotency_mismatch")
    public static let invalidReply = Self(rawValue: "invalid_reply")
    // 426
    public static let upgradeClient = Self(rawValue: "upgrade_client")
    public static let upgradeMac = Self(rawValue: "upgrade_mac")
    // 429
    public static let rateLimited = Self(rawValue: "rate_limited")
    // 503
    public static let remoteOff = Self(rawValue: "remote_off")
    public static let notReady = Self(rawValue: "not_ready")
    public static let tmuxMissing = Self(rawValue: "tmux_missing")
}

public struct APIError: Codable, Hashable, Sendable, Error {
    public let code: ErrorCode
    /// Plain English, safe to show.
    public let message: String
    /// True only for 429, 503 and `in_progress`.
    public let retryable: Bool
    public let details: [String: String]?
    public init(code: ErrorCode, message: String, retryable: Bool = false, details: [String: String]? = nil) {
        self.code = code; self.message = message; self.retryable = retryable; self.details = details
    }
}

/// An error response's body: `{"error": {"code": …, "message": …, "retryable": …, "details": {…}}}`.
public struct ErrorBody: Codable, Hashable, Sendable {
    public let error: APIError
    public init(error: APIError) { self.error = error }
}
