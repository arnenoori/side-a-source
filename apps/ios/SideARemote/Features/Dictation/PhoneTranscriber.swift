import AVFoundation
import Foundation
import SideARemoteShared
import Speech

enum PhoneTranscriber {
    enum Failure: Error { case unsupportedLanguage }

    nonisolated static func transcribe(_ url: URL, hints: [String]) async throws -> String {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined { _ = await authorize() }
        let locale = Locale.current
        let context = AnalysisContext()
        context.contextualStrings[.general] = hints
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let module = SpeechTranscriber(locale: supported, preset: .transcription)
            return try await run(url, module, context: context, results: module.results) { $0.text }
        }
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else { throw Failure.unsupportedLanguage }
        let module = DictationTranscriber(locale: supported, preset: .longDictation)
        return try await run(url, module, context: context, results: module.results) { $0.text }
    }

    nonisolated private static func run<Results: AsyncSequence & Sendable>(_ url: URL, _ module: any SpeechModule, context: AnalysisContext, results: Results,
                                                                           text: @escaping @Sendable (Results.Element) -> AttributedString) async throws -> String {
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await install.downloadAndInstall() }
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [module])
        do { try await analyzer.setContext(context) } catch {
            RemoteLog.error(.app, "The speech analyzer refused its hints: \(error)")
        }
        async let collected = collect(results, text)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }

    nonisolated private static func collect<Results: AsyncSequence & Sendable>(_ results: Results,
                                                                               _ text: @Sendable (Results.Element) -> AttributedString) async throws -> String {
        var words = AttributedString()
        for try await result in results { words += text(result) }
        return String(words.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Off the main actor, so the callback, which runs on a queue of the framework's, isn't taken for main-actor code.
    nonisolated private static func authorize() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}
