import Foundation
import SideACore
import SideAProtocol

extension RemoteRoutes {
    static let transcribeRoutes: [Route] = [Route("POST", "v1/transcribe", transcribe)]

    /// The pairing is enough: nothing on the Mac changes.
    @Sendable static func transcribe(_ context: Context) async -> HTTPResponse {
        let audio = context.request.body
        let ask = TranscribeAsk(query: context.request.query)
        let size = "\(max(audio.count / 1024, 1)) KB", length = ask.seconds.map { "\($0) s" } ?? "? s", device = context.device.prefix(6)
        guard audio.count <= TranscribeRoute.largest, (ask.seconds ?? 0) <= Int(TranscribeRoute.longest) + 10 else {
            RemoteLog.shared("transcription refused (too long), \(length), \(size) for device \(device)")
            return OpenAITranscription.Failure.tooLong.response
        }
        guard let mime = audioType(audio) else { return RemoteServer.error(415, .unsupportedMedia, "Send the recording as M4A or WAV.") }
        let found = await MainActor.run { () -> (credentials: (key: String, model: String)?, folder: String?) in
            let folder = ask.session.flatMap { id in context.controller.store.flatMap { SessionCommands.Target(id, store: $0)?.live?.cwd } }
            return (context.controller.transcription.credentials(), folder)
        }
        guard let credentials = found.credentials else {
            RemoteLog.shared("transcription skipped (no key), \(length), \(size) for device \(device)")
            return OpenAITranscription.Failure.noKey.response
        }
        if let refusal = TranscriptionSpend.shared.begin(context.device) {
            RemoteLog.shared("transcription refused (\(refusal.logName)), \(length), \(size) for device \(device)")
            return refusal.response
        }
        defer { TranscriptionSpend.shared.end(context.device) }
        var files: [String] = []
        if let folder = found.folder { files = await TranscriptionPrompt.files(in: folder) }
        let prompt = TranscriptionPrompt.make(project: found.folder.map { ($0 as NSString).lastPathComponent }, files: files, hint: ask.hint)
        let started = ContinuousClock.now
        do throws(OpenAITranscription.Failure) {
            let text = try await OpenAITranscription.transcribe(audio, mime: mime, key: credentials.key, model: credentials.model,
                                                                prompt: prompt, language: ask.language)
            RemoteLog.shared("transcribed \(length), \(size) with \(credentials.model) in \(OpenAITranscription.elapsed(since: started)) for device \(device)")
            return json(200, TranscribeResult(text: text))
        } catch {
            RemoteLog.shared("transcription failed (\(error.logName)), \(length), \(size) with \(credentials.model) for device \(device)")
            return error.response
        }
    }

    static func audioType(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        guard head.count == 12 else { return nil }
        if Array(head[4..<8]) == Array("ftyp".utf8) { return "audio/mp4" }
        if Array(head[0..<4]) == Array("RIFF".utf8), Array(head[8..<12]) == Array("WAVE".utf8) { return "audio/wav" }
        return nil
    }
}

/// What a stolen token can spend of the Mac's speech-to-text credit before the phone is removed.
final class TranscriptionSpend: @unchecked Sendable {
    static let shared = TranscriptionSpend()
    static let window: TimeInterval = 3600
    static let hourly = 120

    enum Refusal {
        case busy
        case spent(retryAfter: TimeInterval)

        var logName: String {
            switch self {
            case .busy: "one already in flight"
            case .spent: "hourly limit"
            }
        }

        var response: HTTPResponse {
            switch self {
            case .busy:
                RemoteServer.error(429, .transcribeLimited, "The Mac is still transcribing this iPhone's last recording.", retryAfter: 5)
            case .spent(let wait):
                RemoteServer.error(429, .transcribeLimited, "This iPhone has sent \(TranscriptionSpend.hourly) recordings in the last hour.",
                                   retryAfter: max(1, Int(wait.rounded(.up))))
            }
        }
    }

    private let lock = NSLock()
    private var flying: Set<String> = []
    private var recent: [String: [Date]] = [:]

    func begin(_ device: String, now: Date = .now) -> Refusal? {
        lock.withLock {
            if flying.contains(device) { return .busy }
            let hour = (recent[device] ?? []).filter { now.timeIntervalSince($0) < Self.window }
            if hour.count >= Self.hourly, let first = hour.first {
                recent[device] = hour
                return .spent(retryAfter: Self.window - now.timeIntervalSince(first))
            }
            recent[device] = hour + [now]
            flying.insert(device)
            return nil
        }
    }

    func end(_ device: String) {
        lock.withLock { _ = flying.remove(device) }
    }
}
