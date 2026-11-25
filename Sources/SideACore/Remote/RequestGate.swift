import Foundation
import SideAProtocol

/// What a Remote server checks on every request before it runs a route, in the order the Mac's `RemoteServer.handle`
/// does: Host and Origin, the budget for strangers and for pairing attempts, whether the caller may use this route
/// unauthenticated, the device's own rate limits, and a phone too old to sign. A listener (Network.framework on the
/// Mac, SwiftNIO on Linux) keeps one gate and asks it; `nil` means run the route.
public struct RequestGate: Sendable {
    public struct Refusal: Sendable, Equatable {
        public let status: Int
        public let code: ErrorCode
        public let message: String
        public let retryAfter: Int?
        /// 401s carry `WWW-Authenticate: Bearer`.
        public let challenge: Bool
    }

    private var strangers: [String: RemotePolicy.TokenBucket] = [:]
    private var unauthenticated: RemotePolicy.TokenBucket
    private var attempts: RemotePolicy.TokenBucket
    private var perDevice: [String: RemotePolicy.TokenBucket] = [:]
    private var answers: [String: RemotePolicy.TokenBucket] = [:]

    public init(now: TimeInterval) {
        unauthenticated = RemotePolicy.TokenBucket(rate: 1, burst: 40, now: now)
        attempts = RemotePolicy.TokenBucket(rate: 1, burst: 10, now: now)
    }

    /// `device` is the id whose token the request carried, nil for none or an unknown one.
    public mutating func admit(_ request: HTTPRequest, source: String, device: String?, hosts: Set<String>, port: UInt16,
                               now: TimeInterval) -> Refusal? {
        switch RemotePolicy.check(request.headers, hosts: hosts, port: port) {
        case .host?: return Self.refusal(421, .badHost, "This address isn't one of this computer's own.")
        case .browser?: return Self.refusal(403, .forbiddenOrigin, "Browsers can't use Side A Remote.")
        case nil: break
        }
        let open = Self.open(request)
        if let device {
            if let wait = perDevice[device, default: RemotePolicy.TokenBucket(rate: 20, burst: 60, now: now)].take(now: now) { return Self.limited(wait) }
            if Self.answering(request), let wait = answers[device, default: RemotePolicy.TokenBucket(rate: 0.5, burst: 30, now: now)].take(now: now) {
                return Self.limited(wait)
            }
            if !open, let build = RemotePolicy.clientBuild(request.headers["X-SideA-Client"]), build < RemotePolicy.minClientBuild {
                return Self.refusal(426, .upgradeClient, "Update Side A Remote to use it with this computer.")
            }
            return nil
        }
        if Self.attempt(request) {
            if let wait = attempts.take(now: now) { return Self.limited(wait) }
        } else {
            if strangers.count > 512 { strangers = [:] }
            if let wait = strangers[RemotePolicy.budget(source), default: RemotePolicy.TokenBucket(rate: 10.0 / 60, burst: 5, lockout: 60, now: now)].take(now: now) {
                return Self.limited(wait)
            }
            if let wait = unauthenticated.take(now: now) { return Self.limited(wait) }
        }
        guard open else {
            return Refusal(status: 401, code: .unauthorized, message: "This device isn't paired with Side A. Pair it again.", retryAfter: nil, challenge: true)
        }
        return nil
    }

    /// Forget a revoked device's budgets.
    public mutating func forget(device: String) { perDevice[device] = nil; answers[device] = nil }

    /// Routes anyone may call: hello, and the pairing exchange.
    public static func open(_ request: HTTPRequest) -> Bool {
        let path = request.path
        if request.method == "GET" && path == ["v1", "hello"] { return true }
        if request.method == "POST" && path == ["v1", "pair"] { return true }
        return attempt(request)
    }

    /// `POST /v1/pair/{id}/wait` and `DELETE /v1/pair/{id}`.
    public static func attempt(_ request: HTTPRequest) -> Bool {
        let path = request.path
        guard path.count >= 3, path[0] == "v1", path[1] == "pair" else { return false }
        return request.method == "POST" && path.count == 4 && path[3] == "wait" || request.method == "DELETE" && path.count == 3
    }

    /// A POST that changes nothing and whose answer must not be kept (dictation).
    public static func unrecorded(_ request: HTTPRequest) -> Bool { request.method == "POST" && request.path == ["v1", "transcribe"] }

    private static func answering(_ request: HTTPRequest) -> Bool {
        [QueuedRoutes.answer, QueuedRoutes.reply, QueuedRoutes.interrupt].contains { $0.matches(method: request.method, components: request.path) }
    }

    private static func refusal(_ status: Int, _ code: ErrorCode, _ message: String) -> Refusal {
        Refusal(status: status, code: code, message: message, retryAfter: nil, challenge: false)
    }

    private static func limited(_ wait: TimeInterval) -> Refusal {
        Refusal(status: 429, code: .rateLimited, message: "Too many requests. Try again shortly.", retryAfter: max(1, Int(wait.rounded(.up))), challenge: false)
    }
}

public extension HTTPResponse {
    /// The error envelope every route answers with (`docs/remote/protocol.md`, Errors).
    static func apiError(_ status: Int, _ code: ErrorCode, _ message: String, details: [String: String]? = nil,
                         retryAfter: Int? = nil) -> HTTPResponse {
        var error: [String: Any] = ["code": code.rawValue, "message": message, "retryable": status == 429 || status == 503 || code == .inProgress]
        if let details { error["details"] = details }
        let body = (try? JSONSerialization.data(withJSONObject: ["error": error], options: [.sortedKeys])) ?? Data()
        var response = HTTPResponse.json(status, body)
        if let retryAfter { response.headers.add("Retry-After", String(retryAfter)) }
        return response
    }

    init(_ refusal: RequestGate.Refusal) {
        var response = HTTPResponse.apiError(refusal.status, refusal.code, refusal.message, retryAfter: refusal.retryAfter)
        if refusal.challenge { response.headers.add("WWW-Authenticate", "Bearer") }
        self = response
    }
}
