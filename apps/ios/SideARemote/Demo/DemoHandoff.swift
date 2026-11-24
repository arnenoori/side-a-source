import Foundation
import SideAProtocol

extension MacTools {
    func demoEarlierPage(_ conversation: String, now: Date = .now) -> TranscriptPage {
        let t = now.timeIntervalSince1970
        let messages = [
            TranscriptMessage(seq: 0, uuid: "h-u1", role: .user, at: t - 25 * 60, text: "Can the phone find the Mac on the same Wi-Fi without Tailscale?"),
            TranscriptMessage(seq: 1, uuid: "h-a1", role: .assistant, at: t - 24 * 60, model: "opus",
                              text: "Yes. The Mac can advertise itself over Bonjour, and the phone pins the Mac's self-signed certificate on first use."),
        ]
        return TranscriptPage(sessionID: conversation, generation: "demo", messages: messages, before: nil, after: Cursor("2"), count: messages.count)
    }

    func demoHandoffPrompt() -> String {
        HandoffMessage.openings[0] + "in Claude Opus 5.5. " + HandoffMessage.heading
            + "Add LAN mode: Bonjour discovery and a pinned self-signed certificate."
    }
}

extension DemoData {
    static func withNewRows(_ rows: [RemoteSession], at t: Timestamp) -> [RemoteSession] {
        var live = rows
        for index in live.indices {
            switch live[index].id {
            case ID.ship:
                live[index].pullRequest = PullRequest(url: "https://github.com/alex/side-a/pull/388", number: 388, title: "Ship 0.5.37",
                                                      state: .open, checks: .failing)
            case ID.landing:
                live[index].pullRequest = PullRequest(url: "https://github.com/alex/site/pull/412", number: 412, title: "Tighten the landing page copy",
                                                      state: .open, checks: .passing)
            case ID.lan:
                live[index].handoffFrom = HandoffLink(id: "demo-handoff", conversationID: "8c1d2f3e-claude-lan", agent: .claude, model: "claude-opus-5-5",
                                                      at: t - 9 * 60)
            case "idle-3":
                live[index].failure = SessionFailure(kind: .contextFull, message: "The conversation is too long for the model. Compact it or clear it to go on.",
                                                     retryable: false, fix: .compact, at: t - 130 * 60)
                live[index].abilities.insert(.compact)
            case "idle-5":
                live[index].snooze = SessionSnooze(choice: .threeHours, until: t + 2 * 3600, at: t - 3600)
            default: break
            }
        }
        return live
    }
}
