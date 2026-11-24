import SideARemoteKit
import Testing

@Test func everyEventFromEveryDictationPhase() {
    typealias P = DictationPhase
    let events: [P.Event] = [.refused, .started, .transcribe, .transcribed, .failed("No."), .cancelled]
    let table: [P: [P.Event: P]] = [
        .idle: [.refused: .denied, .started: .recording, .failed("No."): .failed("No."), .cancelled: .idle],
        .denied: [.refused: .denied, .started: .recording, .failed("No."): .failed("No."), .cancelled: .idle],
        .recording: [.transcribe: .transcribing, .cancelled: .idle],
        .transcribing: [.transcribed: .idle, .failed("No."): .failed("No."), .cancelled: .idle],
        .failed("Old."): [.transcribe: .transcribing, .cancelled: .idle],
    ]
    for (state, row) in table {
        for event in events { #expect(state.next(event) == row[event], "\(state) \(event)") }
    }
}
