import SideAProtocol

extension TranscriptStore.Delivery {
    /// A request that settled while this phone's answer was in doubt: ours when this device's own answer resolved it,
    /// someone else's otherwise.
    static func afterDoubt(_ resolution: RequestResolution?, thisDevice: String) -> Self {
        resolution?.by == .device && resolution?.deviceID == thisDevice ? .delivered : .answeredElsewhere
    }
}

extension TranscriptStore.AnsweredRequest {
    /// Whether what the phone chose is what happened. A request someone else answered, one that was gone, or an answer
    /// that wasn't sent says nothing of the kind, so the phone's "Denied" can't stand for it. The Mac's own wording
    /// (`.elsewhere`) always stands.
    var chosenHere: Bool {
        switch delivery {
        case .answeredElsewhere, .gone, .failed: outcome.isElsewhere
        default: true
        }
    }

    /// The outcome the row's icon follows: the phone's choice only when it stands.
    var shownOutcome: RequestOutcome { chosenHere ? outcome : .elsewhere("") }

    var line: String {
        let subject: String
        if case .command(let command) = request.action { subject = "\(request.tool) \(command)" } else { subject = request.headline }
        guard chosenHere else {
            if case .failed = delivery { return "Not sent · \(subject)" }
            return "Answered elsewhere · \(subject)"
        }
        switch outcome {
        case .denied where request.plan != nil: return "Kept planning"
        case .allowed, .denied, .elsewhere: return "\(outcome.line) · \(subject)"
        default: return outcome.line
        }
    }
}
