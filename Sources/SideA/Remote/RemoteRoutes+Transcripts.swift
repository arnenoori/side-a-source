import Foundation
import SideACore
import SideAProtocol

/// Transcripts and their images, read through the bridge's conversation process. The bridge says where an image's
/// bytes are; the Mac reads them, checks them against the id, and serves them.
extension RemoteRoutes {
    static let transcriptRoutes: [Route] = [
        Route("GET", "v1/sessions/{id}/transcript", transcript),
        Route("GET", "v1/sessions/{id}/messages/{seq}", message),
        Route("GET", "v1/images/{sha1}", image),
        Route("GET", "v1/images/{sha1}/thumb", thumb),
    ]

    static let noImage = RemoteServer.error(404, "image_not_found", "That image isn't on the Mac any more.")

    /// Ids go to the bridge as arguments, so nothing that could read as an option gets through.
    static func safeID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, CharacterSet.alphanumerics.contains(first), id.count <= 128 else { return false }
        return id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
    }

    /// The conversation a phone's session key names: a live session's own id, or the key itself for one that ended.
    static func conversation(_ context: Context) async -> String? {
        let id = context.params["id"] ?? ""
        return await MainActor.run { context.controller.store.flatMap { conversation(id, store: $0) } }
    }

    @MainActor static func conversation(_ key: SessionKey, store: AccountStore) -> String? {
        let conversation = Target(key, store: store)?.conversation ?? (key.hasPrefix("pid-") ? nil : key)
        return conversation.flatMap { safeID($0) ? $0 : nil }
    }

    static func bridge(_ context: Context, _ action: String, _ id: String, _ options: [String] = []) async throws -> Data {
        try await bridge(context, [action] + options + ["--", id])
    }

    static func bridge(_ context: Context, _ args: [String]) async throws -> Data {
        guard let store = await MainActor.run(body: { context.controller.store }) else { throw BridgeFailure(message: "Remote is starting.") }
        return try await store.sessions.remoteReply(args)
    }

    static func failed(_ error: Error) -> HTTPResponse {
        switch error {
        case let failure as RemoteTranscript.Failure where failure.missing: noSession
        case let failure as RemoteTranscript.Failure where failure.badCursor: RemoteServer.error(400, "bad_request", "That cursor isn't one this Mac gave out.")
        case is BridgeFailure: RemoteServer.error(503, "not_ready", "Side A is still starting its session reader.", retryAfter: 2)
        default: RemoteServer.error(500, "internal", "Side A couldn't read that session.")
        }
    }

    @Sendable static func transcript(_ context: Context) async -> HTTPResponse {
        let query = context.request.query
        if query["before"] != nil, query["after"] != nil { return RemoteServer.error(400, "bad_request", "Send before or after, not both.") }
        guard let conversation = await conversation(context) else { return noSession }
        var options = ["--format", "remote", "--limit", String(min(max(query["limit"].flatMap(Int.init) ?? 50, 1), 200))]
        for key in ["before", "after"] {
            guard let cursor = query[key] else { continue }
            guard safeID(cursor) else { return RemoteServer.error(400, "bad_request", "That cursor isn't one this Mac gave out.") }
            options += ["--\(key)", cursor]
        }
        if let agent = query["agent"] {
            guard safeID(agent) else { return noSession }
            options += ["--agent-id", agent]
        }
        do { return json(200, try RemoteTranscript.page(try await bridge(context, "show", conversation, options))) } catch { return failed(error) }
    }

    @Sendable static func message(_ context: Context) async -> HTTPResponse {
        guard let seq = context.params["seq"].flatMap(Int.init), seq >= 0,
              let generation = context.request.query["generation"], safeID(generation) else {
            return RemoteServer.error(400, "bad_request", "Send the message's seq and generation.")
        }
        guard let conversation = await conversation(context) else { return noSession }
        var options = ["--seq", String(seq), "--generation", generation]
        if let agent = context.request.query["agent"], safeID(agent) { options += ["--agent-id", agent] }
        do {
            guard let message = try RemoteTranscript.message(try await bridge(context, "message", conversation, options)) else {
                return RemoteServer.error(410, "cursor_expired", "This conversation changed since you loaded it. Load it again.")
            }
            return json(200, message)
        } catch {
            return failed(error)
        }
    }

    /// The bytes, checked against the id; a locator gone stale is re-scanned once.
    static func imageBytes(_ context: Context, _ id: String) async -> (Data, String)? {
        for recheck in [false, true] {
            guard let reply = try? await bridge(context, "image", id, recheck ? ["--recheck"] : []),
                  let location = try? SessionBridge.decode(reply, as: RemoteImages.Location.self), location.error == nil else { return nil }
            let read = await Task.detached { RemoteImages.read(location, id: id) }.value
            if let read { return (read, location.mime ?? "application/octet-stream") }
        }
        return nil
    }

    static func cached(_ context: Context, _ id: String, _ status: Int = 200, mime: String, body: Data) -> HTTPResponse {
        var response = HTTPResponse(status: status, body: body)
        if status == 200 { response.headers.add("Content-Type", mime) }
        response.headers.add("ETag", "\"\(id)\"")
        response.headers.add("Cache-Control", "private, max-age=31536000, immutable")
        return response
    }

    /// Already on the phone: the id is the bytes' hash, so a match is the same image.
    static func unchanged(_ context: Context, _ id: String) -> Bool {
        context.request.headers["If-None-Match"].map { $0.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "\"\(id)\"" } } ?? false
    }

    @Sendable static func image(_ context: Context) async -> HTTPResponse {
        let id = context.params["sha1"]?.lowercased() ?? ""
        guard RemoteImages.isID(id) else { return noImage }
        if unchanged(context, id) { return cached(context, id, 304, mime: "", body: Data()) }
        guard let (bytes, mime) = await imageBytes(context, id) else { return noImage }
        return cached(context, id, mime: mime, body: bytes)
    }

    @Sendable static func thumb(_ context: Context) async -> HTTPResponse {
        let id = context.params["sha1"]?.lowercased() ?? ""
        guard RemoteImages.isID(id), let root = await MainActor.run(body: { context.controller.store?.root }) else { return noImage }
        if unchanged(context, id) { return cached(context, id, 304, mime: "", body: Data()) }
        let folder = root.appendingPathComponent("runtime/thumbs")
        if let saved = try? Data(contentsOf: folder.appendingPathComponent(id + ".jpg")) { return cached(context, id, mime: "image/jpeg", body: saved) }
        guard let (bytes, _) = await imageBytes(context, id),
              let thumb = await Task.detached(operation: { RemoteImages.thumbnail(bytes, id: id, folder: folder) }).value else { return noImage }
        return cached(context, id, mime: "image/jpeg", body: thumb)
    }
}
