import Foundation

/// Each pool account's token and the one bridge read renewing it, for the app and the helper alike.
@MainActor public final class PoolTokenCache {
    private var tokens: [String: (credential: PoolCredential, expires: Double, hash: String)] = [:]
    private var reads: [String: (id: UUID, forced: Bool, task: Task<PoolCredential, any Error>)] = [:]
    /// Outlives `forget`, so a renewal forced after a 401 still names the token it must not bring back.
    private var hashes: [String: String] = [:]

    public init() {}

    /// `refused`: the account just turned the cached token away, so the bridge must renew it rather than read it back.
    public func token(_ account: String, refused: Bool, codex: Bool, now: Double,
                      bridge: @escaping ([String]) async throws -> Data) async throws -> PoolCredential {
        // The bridge renews five minutes ahead, so a token kept until four minutes ahead is never one it would keep too.
        if !refused, let cached = tokens[account], cached.expires - 240 > now { return cached.credential }
        // A session's subagents ask at once; one bridge run answers them all. A read that wasn't forced may bring back
        // the very token just refused, so a refusal doesn't wait on one.
        if let pending = reads[account], pending.forced || !refused { return try await pending.task.value }
        let args = [codex ? "codex-pool-token" : "pool-token", account] + (refused ? hashes[account].map { ["--refused", $0] } ?? [] : [])
        let id = UUID()
        let task = Task { [weak self] in
            struct Token: Decodable { let accessToken: String; let accountId: String?; let expiresAt: Double; let hash: String }
            let token = try JSONDecoder().decode(Token.self, from: try await bridge(args))
            let credential = PoolCredential(token: token.accessToken, accountID: token.accountId)
            // A forced read that overtook this one has the newer token.
            if self?.reads[account]?.id == id {
                self?.tokens[account] = (credential, token.expiresAt / 1000, token.hash)
                self?.hashes[account] = token.hash
            }
            return credential
        }
        reads[account] = (id, refused, task)
        defer { if reads[account]?.id == id { reads[account] = nil } }
        return try await task.value
    }

    /// A read already under way may return the token just turned away, so it isn't kept either.
    public func forget(_ account: String) {
        tokens[account] = nil
        reads[account] = nil
    }
}
