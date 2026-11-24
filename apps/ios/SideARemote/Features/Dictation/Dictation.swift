import AVFoundation
import Observation
import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftUI

@Observable
final class Dictation {
    nonisolated deinit {}

    typealias Phase = DictationPhase

    struct Target {
        var text: Binding<String>
        var selection: Binding<NSRange>
        var focused: Binding<Bool>
        var model: AppModel
        var ask = TranscribeAsk()
        var words: [String] = []
        var shelf: String?
    }

    static let limit = TranscribeRoute.longest
    static let closing: TimeInterval = 30
    static let bars = 40
    static let asksBeforeDiscarding: TimeInterval = 10

    private(set) var phase: Phase = .idle
    private(set) var levels: [Float] = Array(repeating: 0, count: bars)
    private(set) var elapsed: TimeInterval = 0
    private(set) var note: String?
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var failures = 0

    var isActive: Bool { phase != .idle }
    var isBusy: Bool { phase == .recording || phase == .transcribing }
    var canRetry: Bool { file != nil }
    var holdsRecording: Bool { isBusy || canRetry }
    var asksToDiscard: Bool { isBusy && elapsed > Self.asksBeforeDiscarding }

    @ObservationIgnored var target: Target?
    @ObservationIgnored private let recorder = DictationRecorder()
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var kept: String?
    @ObservationIgnored private var meter: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var noting: Task<Void, Never>?

    init() {
        recorder.onInterrupted = { [weak self] in self?.finish() }
    }

    func begin() async {
        guard phase == .idle || phase == .denied else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            guard await AVAudioApplication.requestRecordPermission() else { return move(.refused) }
            // While iOS asked, an earlier recording may have been put back for Retry; recording now would lose it.
            guard phase == .idle || phase == .denied else { return }
        case .denied:
            move(.refused)
            return
        default: break
        }
        note = nil
        target?.focused.wrappedValue = false
        do {
            file = try recorder.start()
        } catch {
            failures += 1
            move(.failed("The microphone couldn't start. Try again in a moment."))
            return
        }
        elapsed = 0
        levels = Array(repeating: 0, count: Self.bars)
        move(.started)
        starts += 1
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, self.phase == .recording else { return }
                self.levels = Array(self.levels.dropFirst()) + [self.recorder.level]
                self.elapsed = self.recorder.time
                if self.elapsed >= Self.limit { return self.finish() }
            }
        }
    }

    func finish() {
        guard phase == .recording else { return }
        elapsed = max(elapsed, recorder.time)
        meter?.cancel()
        recorder.stop()
        stops += 1
        transcribe()
    }

    func cancel(refocus: Bool = true) {
        meter?.cancel()
        work?.cancel()
        if recorder.isRecording { recorder.stop() }
        discard()
        move(.cancelled)
        if refocus { target?.focused.wrappedValue = true }
    }

    func adopt() {
        guard phase == .idle, file == nil, let key = target?.shelf, let url = DictationShelf.shared.recording(for: key) else { return }
        file = url
        kept = key
        elapsed = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
        move(.failed("An earlier recording couldn't be transcribed. It's kept."))
    }

    func retry() {
        guard canRetry else { return cancel() }
        transcribe()
    }

    func leave() {
        if phase == .recording { finish() } else if phase == .denied { move(.cancelled) }
    }

    private func transcribe() {
        guard let file, let target else { return cancel() }
        // The field may be another session's by the time this fails; the recording belongs to this one.
        let shelf = target.shelf
        move(.transcribe)
        let seconds = elapsed
        work = Task { [self] in
            do {
                let (words, fellBack) = try await Self.words(file, seconds: seconds, target: target)
                guard !Task.isCancelled else { return }
                deliver(words, fellBack: fellBack)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                failures += 1
                keep(under: shelf)
                move(.failed(Self.message(error)))
            }
        }
    }

    private func keep(under key: String?) {
        guard let file, let key, key != kept, let moved = DictationShelf.shared.keep(file, for: key) else { return }
        if let kept { DictationShelf.shared.remove(kept) }
        self.file = moved
        kept = key
    }

    private static func words(_ file: URL, seconds: TimeInterval, target: Target) async throws -> (String, String?) {
        let tools = target.model.tools
        let mac = target.model.mac.name
        var reason: String?
        if !DictationPrefs.onPhone, tools.isLive, tools.can(.transcribe), target.model.mac.state == .live {
            var ask = target.ask
            ask.seconds = Int(seconds.rounded())
            ask.language = language
            do {
                let audio = try Data(contentsOf: file)
                return (try await tools.transcribe(audio, ask).text, nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as RemoteFailure {
                reason = switch failure.error.code {
                case .transcribeNoKey: "no key on \(mac)"
                case .transcribeKeyRefused: "\(mac)'s key was refused"
                default: "\(mac) couldn't transcribe"
                }
            } catch {
                reason = "\(mac) didn't answer"
            }
            try Task.checkCancellation()
        }
        let words = try await PhoneTranscriber.transcribe(file, hints: target.words)
        return (words, "Transcribed on this \(ThisDevice.kind)" + (reason.map { " · \($0)" } ?? ""))
    }

    private func deliver(_ words: String, fellBack: String?) {
        discard()
        move(.transcribed)
        guard let target else { return }
        defer { target.focused.wrappedValue = true }
        guard !words.isEmpty else { return say("Didn't catch anything.") }
        let placed = Self.insert(words, into: target.text.wrappedValue, at: target.selection.wrappedValue)
        target.text.wrappedValue = placed.text
        target.selection.wrappedValue = NSRange(location: placed.caret, length: 0)
        if let fellBack { say(fellBack) }
    }

    private func move(_ event: Phase.Event) { if let next = phase.next(event) { phase = next } }

    private func say(_ text: String) {
        note = text
        noting?.cancel()
        noting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.note = nil }
        }
    }

    private func discard() {
        if let kept { DictationShelf.shared.remove(kept) } else if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        kept = nil
    }

    static func insert(_ words: String, into text: String, at selection: NSRange) -> (text: String, caret: Int) {
        let whole = text as NSString
        let untouched = selection.location == 0 && selection.length == 0 && whole.length > 0
        let start = untouched ? whole.length : min(selection.location, whole.length)
        let end = untouched ? whole.length : min(start + selection.length, whole.length)
        func character(_ at: Int) -> Character? { at >= 0 && at < whole.length ? Character(whole.substring(with: NSRange(location: at, length: 1))) : nil }
        let lead = character(start - 1).map { $0.isWhitespace ? "" : " " } ?? ""
        let trail = character(end).map { $0.isWhitespace || $0.isPunctuation ? "" : " " } ?? ""
        let placed = whole.replacingCharacters(in: NSRange(location: start, length: end - start), with: lead + words + trail)
        return (placed, start + ((lead + words) as NSString).length)
    }

    /// The provider guesses better than a wrong hint, and refuses a code it doesn't list.
    static var language: String? {
        let codes = Locale.preferredLanguages.map { code(Locale(identifier: $0).language) }
        guard let first = codes.first.flatMap({ $0 }), codes.allSatisfy({ $0 == first }), providerLanguages.contains(first) else { return nil }
        return first
    }

    static func code(_ language: Locale.Language) -> String? {
        guard let code = language.languageCode?.identifier(.alpha2) else { return nil }
        return code == "nb" || code == "nn" ? "no" : code
    }

    /// From OpenAI's speech-to-text guide.
    static let providerLanguages: Set<String> = [
        "af", "ar", "hy", "az", "be", "bs", "bg", "ca", "zh", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "gl", "de", "el",
        "he", "hi", "hu", "is", "id", "it", "ja", "kn", "kk", "ko", "lv", "lt", "mk", "ms", "mr", "mi", "ne", "no", "fa", "pl",
        "pt", "ro", "ru", "sr", "sk", "sl", "es", "sw", "sv", "tl", "ta", "th", "tr", "uk", "ur", "vi", "cy",
    ]

    static func message(_ error: Error) -> String {
        switch error {
        case PhoneTranscriber.Failure.unsupportedLanguage: "This \(ThisDevice.kind) can't transcribe this language on its own. The recording is kept."
        default: "Couldn't transcribe the recording. It's kept."
        }
    }
}

extension Dictation.Target {
    init(text: Binding<String>, selection: Binding<NSRange>, focused: Binding<Bool>, model: AppModel, session: RemoteSession?, project: String? = nil,
         shelf: String? = nil) {
        let project = project ?? session?.project
        self.init(text: text, selection: selection, focused: focused, model: model,
                  ask: TranscribeAsk(session: session?.id, hint: [project, session.map { model.tools.title(for: $0) }].compactMap(\.self).joined(separator: ", ")),
                  words: [project, "Claude", "Codex", "Side A"].compactMap(\.self), shelf: shelf ?? session?.id)
    }
}

/// Where a recording is turned into words. The host's transcription is the default where it has one; choosing
/// the phone keeps the audio on it.
enum DictationPrefs {
    static let key = "dictation.onPhone"
    static var onPhone: Bool { SharedStorage.defaults.bool(forKey: key) }
}
