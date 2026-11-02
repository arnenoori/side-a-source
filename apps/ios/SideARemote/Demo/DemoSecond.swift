import Foundation
import SideAProtocol

extension DemoData {
    /// `--demo-macs 2`: a Mac mini beside the MacBook Pro, with its own sessions and one account in common.
    var second: DemoData {
        let t = now.timeIntervalSince1970
        func ago(_ minutes: Double) -> Timestamp { t - minutes * 60 }
        let sessions = [
            RemoteSession(id: "mini-backup", conversationID: "mini-backup", agent: .claude, title: "Rotate the backup keys",
                          cwd: "~/Coding/backups", project: "backups", accountID: "work", accountName: "Work", model: "sonnet",
                          status: .working, statusAt: ago(4), step: "Running restic check", hosted: "sa-backups-2a1d",
                          abilities: [.transcript, .type, .interrupt, .terminal, .end]),
            // Two-way terminal: Codex through its shared server, mid-turn; Codex outside it; Claude through its inbox.
            RemoteSession(id: "mini-uptime", conversationID: "mini-uptime", agent: .codex, title: "Page on two failed probes",
                          cwd: "~/Coding/uptime", project: "uptime", accountID: "lab", accountName: "Lab", model: "gpt-5-codex",
                          status: .working, statusAt: ago(2), step: "Editing prober.ts",
                          flag: SessionFlag(kind: .unsent, text: "Didn't reach Codex: \"Also page when the TLS check fails\""),
                          abilities: [.transcript, .replyTerminal, .interrupt, .followUp]),
            RemoteSession(id: "mini-dns", conversationID: "mini-dns", agent: .codex, title: "Move DNS to Cloudflare",
                          cwd: "~/Coding/home", project: "home", accountID: "lab", accountName: "Lab", model: "gpt-5",
                          status: .working, statusAt: ago(7), step: "Reading zone.txt", abilities: [.transcript]),
            RemoteSession(id: "mini-notes", conversationID: "mini-notes", agent: .claude, title: "Summarize the outage notes",
                          cwd: "~/Coding/home", project: "home", accountID: "work", accountName: "Work", model: "sonnet",
                          status: .idle, statusAt: ago(9), lastReplyAt: ago(9), step: "Wrote outage.md",
                          abilities: [.transcript, .replyInbox]),
            RemoteSession(id: "mini-idle", agent: .claude, title: "Clean up old Docker images", project: "home", accountName: "Work",
                          model: "haiku", status: .idle, statusAt: ago(180), abilities: [.transcript]),
        ]
        let extras: [SessionKey: SessionExtras] = [
            "mini-backup": SessionExtras(startedAt: now.addingTimeInterval(-25 * 60), lastReply: "Both repositories check clean so far."),
            "mini-uptime": SessionExtras(startedAt: now.addingTimeInterval(-40 * 60), lastReply: "Two misses in a row now page; one doesn't."),
            "mini-dns": SessionExtras(startedAt: now.addingTimeInterval(-15 * 60)),
            "mini-notes": SessionExtras(startedAt: now.addingTimeInterval(-30 * 60), lastReply: "The notes are in outage.md."),
            "mini-idle": SessionExtras(startedAt: now.addingTimeInterval(-300 * 60)),
        ]
        let accounts = self.accounts.filter { $0.id == "work" } + [
            RemoteAccount(id: "lab", name: "Lab", email: "alex@lab.example", provider: .codex, ready: true, active: true,
                          usage: AccountUsage(windows: [
                            UsageWindow(id: "five_hour", label: "5-hour", percent: 18, resetsAt: t + 4 * 3600),
                            UsageWindow(id: "seven_day", label: "Weekly", percent: 22, resetsAt: t + 5 * 86_400),
                          ]), readAt: ago(3), sessions: 1),
        ]
        return DemoData(now: now, sessions: sessions, extras: extras, requests: [], transcripts: [
                            "mini-uptime": [
                                TranscriptMessage(seq: 0, uuid: "u0", role: .user, at: ago(12), text: "Page on two failed probes in a row, not one."),
                                TranscriptMessage(seq: 1, uuid: "a1", role: .assistant, at: ago(11), model: "gpt-5-codex",
                                                  text: "Two misses in a row now page; one doesn't."),
                            ],
                            "mini-notes": Self.shortTranscript(prompt: "Summarize the outage notes into outage.md.",
                                                               reply: "The notes are in outage.md.", running: nil, now: now),
                        ], earlier: [:],
                        accounts: accounts, autopilot: [], history: Array(history.suffix(3)))
    }

    private init(now: Date, sessions: [RemoteSession], extras: [SessionKey: SessionExtras], requests: [RemoteRequest],
                 transcripts: [SessionKey: [TranscriptMessage]], earlier: [SessionKey: Int], accounts: [RemoteAccount],
                 autopilot: [AutopilotDecision], history: [PastSession]) {
        self.now = now; self.sessions = sessions; self.extras = extras; self.requests = requests; self.transcripts = transcripts
        self.earlier = earlier; self.accounts = accounts; self.autopilot = autopilot; self.history = history
    }
}
