import AVFoundation
import Foundation
import Observation
import SideACore
import SideAProtocol

/// The speech-to-text key lives on the Mac so that the phone never holds one.
@MainActor @Observable
final class RemoteTranscription {
    static let modelKey = "remote.transcription.model"
    static let presets = ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]

    enum Test: Equatable { case idle, running, heard(String), failed(String) }

    private(set) var hasKey = false
    private(set) var masked: String?
    private(set) var model: String
    private(set) var test: Test = .idle
    private(set) var error: String?

    @ObservationIgnored private let keychain: RemoteKeychain
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var loaded = false

    init(keychain: RemoteKeychain) {
        self.keychain = keychain
        // swiftlint:disable:next user_defaults_standard -- this type owns the chosen transcription model
        model = UserDefaults.standard.string(forKey: Self.modelKey) ?? Self.presets[0]
    }

    func load() {
        guard !loaded else { return }
        do {
            key = try keychain.transcriptionKey()
            loaded = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        shown()
    }

    func credentials() -> (key: String, model: String)? {
        load()
        guard let key else { return nil }
        return (key, model.isEmpty ? Self.presets[0] : model)
    }

    func save(_ entered: String) {
        let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keychain.writeTranscriptionKey(trimmed)
            key = trimmed
            loaded = true
            error = nil
            test = .idle
        } catch {
            self.error = error.localizedDescription
        }
        shown()
    }

    func remove() {
        keychain.deleteTranscriptionKey()
        key = nil
        loaded = true
        test = .idle
        shown()
    }

    func setModel(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != model else { return }
        model = trimmed
        // swiftlint:disable:next user_defaults_standard -- this type owns the chosen transcription model
        UserDefaults.standard.set(trimmed, forKey: Self.modelKey)
        test = .idle
    }

    func runTest() async {
        guard let credentials = credentials(), test != .running else { return }
        test = .running
        guard let sample = await TranscriptionSample.make() else {
            test = .failed("The Mac couldn't make the test recording.")
            return
        }
        let started = ContinuousClock.now
        do throws(OpenAITranscription.Failure) {
            let text = try await OpenAITranscription.transcribe(sample, mime: "audio/mp4", key: credentials.key, model: credentials.model,
                                                                prompt: nil, language: nil)
            RemoteLog.shared("transcription test ok with \(credentials.model), \(sample.count / 1024) KB in \(OpenAITranscription.elapsed(since: started))")
            test = .heard(text)
        } catch {
            RemoteLog.shared("transcription test failed (\(error.logName)) with \(credentials.model)")
            test = .failed(error.message)
        }
    }

    private func shown() {
        hasKey = key != nil
        masked = key.map { $0.count > 12 ? "\($0.prefix(3))…\($0.suffix(4))" : String(repeating: "•", count: 8) }
    }
}

/// Ephemeral, so nothing of the audio or the words reaches the disk.
enum OpenAITranscription {
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    enum Failure: Error, Equatable {
        case noKey, refused, unreachable, tooLong
        case provider(String)

        var status: Int {
            switch self {
            case .noKey: 503
            case .refused, .provider: 502
            case .unreachable: 504
            case .tooLong: 413
            }
        }

        var code: ErrorCode {
            switch self {
            case .noKey: .transcribeNoKey
            case .refused: .transcribeKeyRefused
            case .unreachable: .transcribeUnreachable
            case .tooLong: .transcribeTooLong
            case .provider: .transcribeFailed
            }
        }

        var message: String {
            switch self {
            case .noKey: "Add an OpenAI key in Side A's Settings on the Mac, under iPhone."
            case .refused: "OpenAI refused the transcription key on the Mac."
            case .unreachable: "The Mac couldn't reach OpenAI."
            case .tooLong: "That recording is longer than \(Int(TranscribeRoute.longest / 60)) minutes."
            case .provider(let message): message
            }
        }

        /// For the log: never the provider's words, which could quote the request.
        var logName: String {
            switch self {
            case .noKey: "no key"
            case .refused: "key refused"
            case .unreachable: "unreachable"
            case .tooLong: "too long"
            case .provider: "provider error"
            }
        }

        var response: HTTPResponse { RemoteServer.error(status, code, message) }
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = TranscribeRoute.macProvider
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    static func transcribe(_ audio: Data, mime: String, key: String, model: String, prompt: String?, language: String?) async throws(Failure) -> String {
        let boundary = "SideA-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var fields = [("model", model), ("response_format", "json")]
        if let prompt, !prompt.isEmpty { fields.append(("prompt", prompt)) }
        if let language, !language.isEmpty { fields.append(("language", language)) }
        request.httpBody = form(fields, file: audio, name: mime == "audio/wav" ? "speech.wav" : "speech.m4a", mime: mime, boundary: boundary)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw .unreachable }
        guard let http = response as? HTTPURLResponse else { throw .unreachable }
        switch http.statusCode {
        case 200..<300:
            guard let result = try? JSONDecoder().decode(TranscribeResult.self, from: data) else { throw .provider("OpenAI's answer couldn't be read.") }
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case 401, 403: throw .refused
        case 413: throw .tooLong
        case 429: throw .provider("OpenAI is busy, or the account is out of credit.")
        default: throw .provider(said(data).map { "OpenAI: \($0)" } ?? "OpenAI answered \(http.statusCode).")
        }
    }

    static func form(_ fields: [(String, String)], file: Data, name: String, mime: String, boundary: String) -> Data {
        var body = Data()
        for (field, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func said(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (object["error"] as? [String: Any])?["message"] as? String, !message.isEmpty else { return nil }
        return String(message.prefix(200))
    }

    static func elapsed(since start: ContinuousClock.Instant) -> String {
        let taken = (ContinuousClock.now - start).components
        return String(format: "%.1f s", Double(taken.seconds) + Double(taken.attoseconds) / 1e18)
    }
}

enum TranscriptionPrompt {
    static let vocabulary = ["Claude", "Claude Code", "Codex", "Side A", "Git", "GitHub", "pull request", "PR", "commit", "rebase", "merge",
                             "Swift", "SwiftUI", "Xcode", "TypeScript", "JavaScript", "Python", "JSON", "API", "CLI", "npm", "README",
                             "refactor", "lint", "worktree", "localhost", "async", "enum", "struct"]
    static let longest = 900

    static func make(project: String?, files: [String], hint: String?) -> String {
        var words: [String] = []
        if let project, !project.isEmpty { words.append(project) }
        if let hint, !hint.isEmpty { words.append(hint) }
        var seen = Set<String>()
        for file in files {
            let name = (file as NSString).lastPathComponent
            if !name.hasPrefix("."), seen.insert(name).inserted { words.append(name) }
        }
        words += vocabulary
        var prompt = "A message to a coding agent. It may mention: "
        for (index, word) in words.enumerated() {
            let piece = (index == 0 ? "" : ", ") + word
            guard prompt.count + piece.count < longest else { break }
            prompt += piece
        }
        return prompt + "."
    }

    /// Only names git lists, never a walk: a folder that isn't a repository, or one holding the home folder, would
    /// send the names of the user's own documents to the provider.
    static func files(in folder: String) async -> [String] {
        guard let root = FileReads.real(folder), !FileReads.wide(root) else { return [] }
        guard let paths = await FileMentions.gitListed(root, timeout: TranscribeRoute.macListing) else { return [] }
        let home = FileReads.real(NSHomeDirectory())
        return FileRank.matches("", in: paths.filter { FileReads.listable($0, root: root, home: home) })
    }
}

enum TranscriptionSample {
    static let phrase = "Side A dictation test. Ask Claude to fix the failing build."
    static let rate: Double = 16_000

    static func make() async -> Data? {
        await Task.detached {
            let (samples, rate) = await spoken() ?? (Array(repeating: 0, count: Int(Self.rate)), Self.rate)
            return m4a(samples, rate: rate)
        }.value
    }

    private final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var samples: [Float] = []
        var rate: Double = 22_050
    }

    nonisolated private static func spoken() async -> ([Float], Double)? {
        let collector = Collector()
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: phrase)
        var timeout: Task<Void, Never>?
        let done: Bool = await withCheckedContinuation { continuation in
            let resume = Once(continuation)
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { return resume(true) }
                collector.lock.withLock {
                    collector.rate = pcm.format.sampleRate
                    let count = Int(pcm.frameLength)
                    if let floats = pcm.floatChannelData?[0] {
                        collector.samples += UnsafeBufferPointer(start: floats, count: count)
                    } else if let ints = pcm.int16ChannelData?[0] {
                        collector.samples += (0..<count).map { Float(ints[$0]) / Float(Int16.max) }
                    }
                }
            }
            timeout = Task { try? await Task.sleep(for: .seconds(8)); resume(false) }
        }
        timeout?.cancel()
        _ = synthesizer
        let (samples, rate) = collector.lock.withLock { (collector.samples, collector.rate) }
        guard done || !samples.isEmpty, samples.count > Int(rate / 2) else { return nil }
        return (samples, rate)
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func callAsFunction(_ value: Bool) {
            lock.withLock { continuation.take() }?.resume(returning: value)
        }
    }

    /// AVAudioFile writes AAC only to a file, so the Mac's own phrase passes through the temporary folder.
    static func m4a(_ samples: [Float], rate: Double) -> Data? {
        guard let resampled = resample(samples, from: rate) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SideA-dictation-test-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        // Some encoders refuse an exact bit rate at 16 kHz.
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1]
        let written = write(resampled, to: url, settings: settings.merging([AVEncoderBitRateKey: 32_000]) { $1 })
            || write(resampled, to: url, settings: settings.merging([AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]) { $1 })
        return written ? try? Data(contentsOf: url) : nil
    }

    /// The file is finished only when released; macOS 14 has no `close()`.
    private static func write(_ buffer: AVAudioPCMBuffer, to url: URL, settings: [String: Any]) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) else { return false }
        return (try? file.write(from: buffer)) != nil
    }

    private static func resample(_ samples: [Float], from rate: Double) -> AVAudioPCMBuffer? {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(samples.count) * Self.rate / rate) + 4096),
              let converter = AVAudioConverter(from: source, to: target), let channel = input.floatChannelData?[0] else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress { channel.update(from: base, count: samples.count) }
        }
        var fed = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in
            if fed { state.pointee = .endOfStream; return nil }
            fed = true
            state.pointee = .haveData
            return input
        }
        return status != .error && output.frameLength > 0 ? output : nil
    }
}
