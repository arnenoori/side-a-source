import AVFoundation
import SideARemoteShared
import UIKit

/// AAC at 16 kHz mono and about 32 kbit/s: five minutes is near 1.2 MB, well inside what the Mac and the relay take.
final class DictationRecorder {
    /// Nonisolated for the iOS 26 abort in the README. A Dictation freed mid-recording would otherwise leave the mic on
    /// and other apps' audio ducked.
    nonisolated deinit {
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        Self.release(AVAudioSession.sharedInstance())
    }

    nonisolated private static func release(_ session: AVAudioSession) {
        do { try session.setActive(false, options: .notifyOthersOnDeactivation) } catch {
            RemoteLog.error(.app, "The audio session couldn't be released: \(error)")
        }
    }

    enum Failure: Error { case couldNotStart }

    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Dictation", isDirectory: true)

    var onInterrupted: () -> Void = {}

    nonisolated(unsafe) private var recorder: AVAudioRecorder?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    var isRecording: Bool { recorder?.isRecording ?? false }
    var time: TimeInterval { recorder?.currentTime ?? 0 }

    var level: Float {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        return max(0, min(1, (decibels + 50) / 45))
    }

    func start() throws -> URL {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let url = Self.folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let recorder = try Self.recorder(url)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw Failure.couldNotStart }
            self.recorder = recorder
        } catch {
            try? FileManager.default.removeItem(at: url)
            Self.release(session)
            throw error
        }
        observe()
        return url
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        Self.release(AVAudioSession.sharedInstance())
    }

    /// Some devices refuse an exact bit rate at 16 kHz; then the encoder picks its own.
    private static func recorder(_ url: URL) throws -> AVAudioRecorder {
        var settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                       AVEncoderBitRateKey: 32_000]
        if let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.prepareToRecord() { return recorder }
        settings[AVEncoderBitRateKey] = nil
        settings[AVEncoderAudioQualityKey] = AVAudioQuality.medium.rawValue
        return try AVAudioRecorder(url: url, settings: settings)
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated { if began { self?.onInterrupted() } }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onInterrupted() }
        })
    }
}
