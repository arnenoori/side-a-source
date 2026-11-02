import Foundation
import SideAProtocol

public struct Endpoint: Sendable, Hashable, Codable {
    public let macID: String
    /// https://100.101.102.103:47800, or the MagicDNS name.
    public let baseURL: URL
    /// Other addresses from pairing or the last hello (MagicDNS, LAN), tried in order when `baseURL` doesn't answer.
    public let alternates: [URL]
    /// The pinned SPKI SHA-256, base64url; every connection checks it.
    public let serverKeyHash: String
    public let name: String
    /// The Mac's relay tunnel, the path when no address answers (docs/remote/tunnel.md).
    public let relay: RelayRoute?
    public init(macID: String, baseURL: URL, alternates: [URL] = [], serverKeyHash: String, name: String, relay: RelayRoute? = nil) {
        self.macID = macID; self.baseURL = baseURL; self.alternates = alternates; self.serverKeyHash = serverKeyHash; self.name = name
        self.relay = relay
    }

    /// Every address, the primary first.
    public var addresses: [URL] { [baseURL] + alternates.filter { $0 != baseURL } }

    /// The same Mac with the addresses its latest `Hello` reported, the current one kept first.
    public func updated(with endpoints: Endpoints) -> Endpoint {
        let lans = endpoints.lans ?? [endpoints.lan].compactMap { $0 }
        let reported = ([endpoints.tailnet, endpoints.name].compactMap { $0 } + lans).filter { !$0.isEmpty }.compactMap { URL(string: "https://\($0)") }
        // A hello to a caller the Mac doesn't know has no addresses, which says nothing about where it is.
        guard !reported.isEmpty else { return self }
        var seen: Set<URL> = [baseURL]
        return Endpoint(macID: macID, baseURL: baseURL, alternates: reported.filter { seen.insert($0).inserted }, serverKeyHash: serverKeyHash, name: name,
                        relay: relay)
    }
}

/// Where tokens live: the keychain group shared with the extensions.
public protocol CredentialStore: Sendable {
    func token(for macID: String) async throws -> String?
    func setToken(_ token: String?, for macID: String) async throws
    /// The 32-byte device secret behind the relay credential `d1.<install>.<device>.<secret>`.
    func relaySecret(for macID: String) async throws -> Data?
}

extension CredentialStore {
    public func relaySecret(for macID: String) async throws -> Data? { nil }
}

/// Who is calling, for `X-SideA-Client` and the capabilities sent in `hello`.
public struct ClientInfo: Sendable, Hashable {
    public let version: String
    public let build: Int
    public let system: String
    public let capabilities: Set<Capability>
    public init(version: String, build: Int, system: String, capabilities: Set<Capability>) {
        self.version = version; self.build = build; self.system = system; self.capabilities = capabilities
    }
    public var header: String { "SideARemote/\(version) (\(build); \(system))" }

    public static let current: ClientInfo = {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let name = "iOS"
        #else
        let name = "macOS"
        #endif
        return ClientInfo(version: info["CFBundleShortVersionString"] as? String ?? "0", build: Int(info["CFBundleVersion"] as? String ?? "") ?? 0,
                          system: "\(name) \(os.majorVersion).\(os.minorVersion)",
                          capabilities: [.events, .transcriptStream, .images, .diffs, .answersQuestions, .answersPlans, .rotation])
    }()
}

/// A response outside 2xx, with the Mac's error when it sent one.
public struct RemoteFailure: Error, Sendable, Equatable {
    public let status: Int
    public let error: APIError
    /// Seconds, from `Retry-After`.
    public let retryAfter: Double?
    public init(status: Int, error: APIError, retryAfter: Double? = nil) { self.status = status; self.error = error; self.retryAfter = retryAfter }

    /// Only what the Mac marks retryable (429, 503, `in_progress`) is tried again with the same key.
    public var retryable: Bool { error.retryable }
}

/// REST calls to one Mac.
public struct RemoteClient: Sendable {
    public let endpoint: Endpoint
    /// The address requests go to: one of `endpoint.addresses`.
    public let address: URL
    let credentials: any CredentialStore
    let transport: any Transport
    let info: ClientInfo
    let cache: ResponseCache

    /// Without a transport, the process's routed one for this Mac: every path pinned to `endpoint.serverKeyHash`.
    public init(endpoint: Endpoint, credentials: any CredentialStore, transport: (any Transport)? = nil, info: ClientInfo = .current,
                address: URL? = nil, cache: ResponseCache = .shared) {
        self.endpoint = endpoint; self.credentials = credentials; self.info = info; self.cache = cache
        self.transport = transport ?? RoutedTransport(paths: .shared(for: endpoint, credentials: credentials))
        self.address = address ?? endpoint.baseURL
    }

    /// The same client on another of the Mac's addresses.
    public func at(_ address: URL) -> RemoteClient {
        RemoteClient(endpoint: endpoint, credentials: credentials, transport: transport, info: info, address: address, cache: cache)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// One path segment, escaped.
    public static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    public func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                        contentType: String = "application/json", idempotencyKey: String? = nil, socket: Bool = false) async throws -> URLRequest {
        var components = URLComponents(url: address, resolvingAgainstBaseURL: false)!
        if socket { components.scheme = components.scheme == "http" ? "ws" : "wss" }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
        components.percentEncodedPath = components.path.split(separator: "/", omittingEmptySubsequences: false)
            .map { Self.segment(String($0)) }.joined(separator: "/")
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(String(ProtocolVersion.current), forHTTPHeaderField: "X-SideA-Protocol")
        request.setValue(info.header, forHTTPHeaderField: "X-SideA-Client")
        if let token = try await credentials.token(for: endpoint.macID) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Sends and checks the status; anything outside 2xx (304 aside) throws `RemoteFailure`. A 401 drops the Mac's cached reads.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) || response.statusCode == 304 else {
            let error = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? APIError(code: ErrorCode(rawValue: "http_\(response.statusCode)"), message: HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                            retryable: response.statusCode == 429 || response.statusCode == 503)
            if response.statusCode == 401 { cache.forget(macID: endpoint.macID) }
            throw RemoteFailure(status: response.statusCode, error: error,
                                retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        }
        return (data, response)
    }

    public func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await read(try await request("GET", path, query: query)))
    }

    /// A GET's body. One the cache keeps goes out with `If-None-Match` when it has a body for it, and a 304 reuses that body.
    func read(_ request: URLRequest) async throws -> Data {
        guard let key = ResponseCache.key(macID: endpoint.macID, request) else { return try await send(request).0 }
        let cached = cache.entry(key)
        var conditional = request
        if let cached { conditional.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await send(conditional)
        if response.statusCode == 304 {
            if let cached { return cached.body }
            // A 304 to a request that named no tag: ask again for the body.
            return try await send(request).0
        }
        if let etag = response.value(forHTTPHeaderField: "ETag") { cache.store(key, etag: etag, body: data) } else { cache.remove(key) }
        return data
    }

    /// `confirm` is an `X-SideA-Confirm` value, for the calls that need one.
    public func post<T: Decodable>(_ path: String, json body: some Encodable, idempotencyKey: String = UUID().uuidString.lowercased(),
                                   confirm: String? = nil, as type: T.Type = T.self) async throws -> T {
        var request = try await request("POST", path, body: try Self.encoder.encode(body), idempotencyKey: idempotencyKey)
        if let confirm { request.setValue(confirm, forHTTPHeaderField: ConfirmSignature.header) }
        let (data, _) = try await send(request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// A body-less mutation that answers nothing the caller keeps.
    func signedSend(_ method: String, _ path: String, confirm: String?) async throws {
        var request = try await request(method, path, idempotencyKey: UUID().uuidString.lowercased())
        if let confirm { request.setValue(confirm, forHTTPHeaderField: ConfirmSignature.header) }
        _ = try await send(request)
    }

    /// `confirm` is an `X-SideA-Confirm` value for the upgrade (the terminal needs one).
    public func socket(_ path: String, confirm: String? = nil) async throws -> any SocketConnection {
        var request = try await request("GET", path, socket: true)
        if let confirm { request.setValue(confirm, forHTTPHeaderField: ConfirmSignature.header) }
        return transport.socket(request)
    }

    // Reads the phone makes outside the sync engine.

    public func hello() async throws -> Hello { try await get("/v1/hello") }
    public func options() async throws -> OptionsList { try await get("/v1/options") }
    public func setup() async throws -> SetupStatus { try await get("/v1/setup") }
    public func registerPush(_ registration: PushRegistration) async throws {
        _ = try await send(try await request("POST", "/v1/devices/push", body: try Self.encoder.encode(registration),
                                             idempotencyKey: UUID().uuidString.lowercased()))
    }
    /// `confirm` signs `ConfirmAction.rekey` with the unlock key: a new key decides who can read this phone's notifications.
    public func rekey(_ rekey: RekeyRequest, confirm: String?) async throws -> RekeyResponse {
        try await post("/v1/devices/rekey", json: rekey, confirm: confirm)
    }
    /// Unpairs this phone on the Mac.
    public func forget() async throws {
        _ = try await send(try await request("DELETE", "/v1/devices/self", idempotencyKey: UUID().uuidString.lowercased()))
    }
    public func testPush() async throws -> DiagnosticPush { try await post("/v1/diagnostics/push", json: [String: String]()) }
    public func pushReceived(_ id: String) async throws {
        _ = try await send(try await request("POST", "/v1/diagnostics/push/\(id)/received", idempotencyKey: UUID().uuidString.lowercased()))
    }
    public func approvals(cursor: Cursor? = nil) async throws -> ApprovalsPage {
        try await get("/v1/approvals", query: cursor.map { [URLQueryItem(name: "cursor", value: $0.raw)] } ?? [])
    }
    public func checkForUpdate() async throws {
        _ = try await send(try await request("POST", "/v1/update/check", idempotencyKey: UUID().uuidString.lowercased()))
    }

    public func sessions() async throws -> SessionList { try await get("/v1/sessions") }
    public func session(_ id: SessionKey) async throws -> RemoteSession { try await get("/v1/sessions/\(id)") }
    public func requests() async throws -> RequestList { try await get("/v1/requests") }
    public func request(_ id: RequestID) async throws -> RemoteRequest { try await get("/v1/requests/\(id)") }
    public func projects() async throws -> ProjectList { try await get("/v1/projects") }
    public func hosted() async throws -> HostedList { try await get("/v1/hosted") }
    public func accounts() async throws -> AccountList { try await get("/v1/accounts") }

    public func search(_ query: String, cursor: Cursor? = nil, limit: Int? = nil) async throws -> SearchResults {
        try await get("/v1/search", query: [URLQueryItem(name: "q", value: query)] + (cursor.map { [URLQueryItem(name: "cursor", value: $0.raw)] } ?? [])
                      + (limit.map { [URLQueryItem(name: "limit", value: String($0))] } ?? []))
    }

    public enum Page: Sendable, Hashable { case latest, before(Cursor), after(Cursor) }

    public func transcript(_ session: SessionKey, _ page: Page = .latest, limit: Int? = nil) async throws -> TranscriptPage {
        var query = limit.map { [URLQueryItem(name: "limit", value: String($0))] } ?? []
        switch page {
        case .latest: break
        case .before(let cursor): query.append(URLQueryItem(name: "before", value: cursor.raw))
        case .after(let cursor): query.append(URLQueryItem(name: "after", value: cursor.raw))
        }
        return try await get("/v1/sessions/\(session)/transcript", query: query)
    }

    public func message(_ session: SessionKey, seq: Int, generation: String) async throws -> TranscriptMessage {
        try await get("/v1/sessions/\(session)/messages/\(seq)", query: [URLQueryItem(name: "generation", value: generation)])
    }

    // Only in Side A. Each needs its capability in `Hello`.

    public func history(archived: Bool = false, project: String? = nil, cursor: Cursor? = nil) async throws -> HistoryPage {
        try await get("/v1/history", query: [URLQueryItem(name: "archived", value: archived ? "1" : "0")]
                      + (project.map { [URLQueryItem(name: "project", value: $0)] } ?? []) + (cursor.map { [URLQueryItem(name: "cursor", value: $0.raw)] } ?? []))
    }
    public func change(_ conversation: String, _ change: HistoryChange) async throws -> PastSession {
        try await post("/v1/history/\(conversation)", json: change)
    }
    public func handoff(_ session: SessionKey) async throws -> Handoff {
        try await post("/v1/sessions/\(session)/handoff", json: [String: String]())
    }
    public func restart(_ session: SessionKey, _ restart: RestartRequest, idempotencyKey: String = UUID().uuidString.lowercased(), confirm: String? = nil) async throws -> HostedSession {
        try await post("/v1/sessions/\(session)/restart", json: restart, idempotencyKey: idempotencyKey, confirm: confirm)
    }
    public func quit(_ session: SessionKey, confirm: String? = nil) async throws {
        try await signedSend("POST", "/v1/sessions/\(session)/quit", confirm: confirm)
    }
    public func quitIdle(olderThanMinutes: Int = 30, confirm: String? = nil) async throws -> QuitIdleResult {
        try await post("/v1/sessions/quit-idle", json: QuitIdleRequest(olderThanMinutes: olderThanMinutes), confirm: confirm)
    }
    public func preview(_ session: SessionKey, port: Int, confirm: String? = nil) async throws -> Preview {
        try await post("/v1/sessions/\(session)/ports/\(port)/preview", json: [String: String](), confirm: confirm)
    }
    public func endPreview(_ session: SessionKey, port: Int) async throws {
        _ = try await send(try await request("DELETE", "/v1/sessions/\(session)/ports/\(port)/preview", idempotencyKey: UUID().uuidString.lowercased()))
    }
    public func stopServer(_ session: SessionKey, port: Int, confirm: String? = nil) async throws {
        try await signedSend("POST", "/v1/sessions/\(session)/ports/\(port)/stop", confirm: confirm)
    }
    public func setMac(_ settings: MacSettings, confirm: String? = nil) async throws -> MacState { try await post("/v1/mac/settings", json: settings, confirm: confirm) }
    public func cleanup() async throws -> CleanupReport { try await get("/v1/cleanup") }
    public func archive(olderThanDays: Int, confirm: String? = nil) async throws -> CleanupResult {
        try await post("/v1/cleanup/archive", json: ArchiveRequest(olderThanDays: olderThanDays), confirm: confirm)
    }
    public func restoreArchived(confirm: String? = nil) async throws -> CleanupResult { try await post("/v1/cleanup/restore", json: [String: String](), confirm: confirm) }
    public func removeWorktree(_ id: String, confirm: String? = nil) async throws {
        try await signedSend("DELETE", "/v1/worktrees/\(id)", confirm: confirm)
    }
    public func autopilot() async throws -> AutopilotState { try await get("/v1/autopilot") }
    public func moveNow(confirm: String? = nil) async throws -> AutopilotState { try await post("/v1/autopilot/move", json: [String: String](), confirm: confirm) }
    /// `confirm` signs `ConfirmMessage.subject(autopilot:)` with the confirm key after Face ID.
    public func setAutopilot(_ change: AutopilotChange, confirm: String, idempotencyKey: String = UUID().uuidString.lowercased()) async throws -> AutopilotState {
        try await post("/v1/autopilot", json: change, idempotencyKey: idempotencyKey, confirm: confirm)
    }
    /// Answering with the recommended choice on or off. `confirm` signs `ConfirmMessage.subject(autopilotAnswers:)` with the
    /// confirm key after Face ID.
    public func setAutopilotAnswers(_ change: AutopilotChange, confirm: String, idempotencyKey: String = UUID().uuidString.lowercased()) async throws -> AutopilotState {
        try await post("/v1/autopilot/answers", json: change, idempotencyKey: idempotencyKey, confirm: confirm)
    }
    /// Makes `id` its provider's active account. `confirm` signs `ConfirmMessage.subject(useAccount:)` with the confirm key
    /// after Face ID. 404, 409 `account_not_ready`.
    public func useAccount(_ id: String, confirm: String, idempotencyKey: String = UUID().uuidString.lowercased()) async throws -> AccountList {
        try await post("/v1/accounts/\(id)/use", json: [String: String](), idempotencyKey: idempotencyKey, confirm: confirm)
    }

    /// `confirm` signs `ConfirmMessage.subject(account:priority:)` with the confirm key after Face ID.
    public func setPriority(_ id: String, _ priority: PriorityLevel, confirm: String, idempotencyKey: String = UUID().uuidString.lowercased()) async throws -> AccountList {
        try await post("/v1/accounts/\(id)/priority", json: PriorityChange(priority: priority), idempotencyKey: idempotencyKey, confirm: confirm)
    }
    /// `confirm` signs `ConfirmMessage.subject(account:auto:)` with the confirm key after Face ID.
    public func setAuto(_ id: String, _ enabled: Bool, confirm: String, idempotencyKey: String = UUID().uuidString.lowercased()) async throws -> AccountList {
        try await post("/v1/accounts/\(id)/auto", json: AutopilotChange(enabled: enabled), idempotencyKey: idempotencyKey, confirm: confirm)
    }
    /// `confirm` signs `ConfirmMessage.subject(swapAt:)` with the confirm key after Face ID.
    public func setSwapAt(_ percent: Int, confirm: String, idempotencyKey: String = UUID().uuidString.lowercased()) async throws -> AutopilotState {
        try await post("/v1/rotation/swap-at", json: SwapAtChange(percent: percent), idempotencyKey: idempotencyKey, confirm: confirm)
    }
    /// `confirm` signs `ConfirmMessage.subject(followFable:)` with the confirm key after Face ID.
    public func setFollowFable(_ enabled: Bool, confirm: String, idempotencyKey: String = UUID().uuidString.lowercased()) async throws -> AutopilotState {
        try await post("/v1/rotation/follow-fable", json: AutopilotChange(enabled: enabled), idempotencyKey: idempotencyKey, confirm: confirm)
    }
    public func outlook() async throws -> UsageOutlook { try await get("/v1/usage/outlook") }

    /// Image bytes, or the thumbnail. Immutable, so callers cache by id.
    public func image(_ id: String, thumbnail: Bool = false) async throws -> Data {
        try await send(try await request("GET", "/v1/images/\(id)" + (thumbnail ? "/thumb" : ""))).0
    }
}
