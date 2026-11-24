import Foundation

public enum DictationPhase: Sendable, Hashable {
    case idle, recording, transcribing
    case failed(String)
    case denied

    public enum Event: Sendable, Hashable {
        case refused
        case started
        case transcribe
        case transcribed
        case failed(String)
        case cancelled
    }

    public func next(_ event: Event) -> Self? {
        switch (self, event) {
        case (_, .cancelled): .idle
        case (.idle, .refused), (.denied, .refused): .denied
        case (.idle, .started), (.denied, .started): .recording
        case (.idle, .failed(let why)), (.denied, .failed(let why)): .failed(why)
        case (.recording, .transcribe), (.failed, .transcribe): .transcribing
        case (.transcribing, .transcribed): .idle
        case (.transcribing, .failed(let why)): .failed(why)
        case (.idle, .transcribe), (.idle, .transcribed), (.denied, .transcribe), (.denied, .transcribed), (.recording, .refused),
             (.recording, .started), (.recording, .transcribed), (.recording, .failed), (.transcribing, .refused), (.transcribing, .started),
             (.transcribing, .transcribe), (.failed, .refused), (.failed, .started), (.failed, .transcribed), (.failed, .failed):
            nil
        }
    }
}
