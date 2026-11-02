#if DEBUG
import Foundation
import SideAProtocol

/// `--demo-stream`: the Ship session writes a reply in bursts the way the Mac's deltas arrive, so the
/// paced reveal can be watched and screenshotted without a Mac.
enum DemoStream {
    static let reply = """
    The version is bumped to **0.5.37** and the changelog has its entry. Next I'll build the release:

    1. Archive with `scripts/release.sh` and notarize.
    2. Upload the DMG and the appcast.
    3. Check that Sparkle offers the update from 0.5.36.

    The island fix is the headline, so it leads the notes.
    """

    static func start(_ model: AppModel, session: SessionKey = DemoData.ID.ship) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            var list = model.transcripts.messages[session] ?? []
            let seq = (list.last?.seq ?? -1) + 1
            var written = ""
            var rest = Substring(reply)
            while !rest.isEmpty {
                // Bursts of 8 to 60 characters, 60 to 400 ms apart.
                let take = rest.prefix(Int.random(in: 8...60))
                written += take
                rest = rest.dropFirst(take.count)
                list.removeAll { $0.seq == seq }
                list.append(TranscriptMessage(seq: seq, uuid: "demo-stream", role: .assistant, at: Date.now.timeIntervalSince1970, text: written))
                model.transcripts.set(list, hasEarlier: false, for: session)
                try? await Task.sleep(for: .milliseconds(Int.random(in: 60...400)))
            }
        }
    }
}
#endif
