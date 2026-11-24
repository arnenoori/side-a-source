import Foundation
import SideAProtocol

extension RemoteClient {
    /// `POST /v1/transcribe`: one recording, sent once. 503 `transcribe_no_key`, 502 `transcribe_key_refused` or
    /// `transcribe_failed`, 504 `transcribe_unreachable`, 413 `transcribe_too_long`.
    public func transcribe(_ audio: Data, mime: String = "audio/mp4", _ ask: TranscribeAsk) async throws -> TranscribeResult {
        var request = try await request("POST", TranscribeRoute.path, query: ask.query, body: audio, contentType: mime)
        request.timeoutInterval = TranscribeRoute.timeout
        return try JSONDecoder().decode(TranscribeResult.self, from: try await send(request).0)
    }
}
