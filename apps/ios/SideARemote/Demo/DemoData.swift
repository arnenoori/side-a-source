import Foundation
import SideAProtocol

/// Fictional sessions, requests, transcripts and accounts for `--demo`, previews, screenshots and
/// App Review. Times are relative to `now`, so the demo never looks stale.
struct DemoData {
    let now: Date
    let sessions: [RemoteSession]
    let extras: [SessionKey: SessionExtras]
    let requests: [RemoteRequest]

    /// The sync request, or with Debug's `--long-requests command|edit` one too long for a card, for checking what's cut;
    /// `--edit-request`, a short edit that offers Allow + Accept Edits.
    private static var long: (tool: String, action: IslandAction, headline: String) {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--edit-request") {
            return ("Edit", .edit(path: "/Users/alex/Coding/side-a/Sources/SyncEngine.swift", removed: "resume()\nawait snapshot.landed()",
                                  added: "await snapshot.landed()\nresume()"), "Allow Edit")
        }
        if let index = arguments.firstIndex(of: "--long-requests"), index + 1 < arguments.count {
            if arguments[index + 1] == "edit" {
                return ("Edit", .edit(path: "/Users/alex/Coding/side-a/Packages/SideAProtocol/Sources/SideARemoteKit/SyncEngine.swift",
                                      removed: "        resume()\n        await snapshot.landed()",
                                      added: "        // Resuming before the snapshot lands replays events the snapshot already holds.\n        await snapshot.landed()\n        resume()"),
                        "Allow Edit")
            }
            return ("Bash", .command("""
                for i in $(seq 1 50); do swift test --filter SyncEngineTests/testSnapshotBeforeResume 2>&1 | tail -1; done \\
                  | sort | uniq -c && git add Sources/SideARemoteKit/SyncEngine.swift Tests/SideARemoteKitTests/SyncEngineTests.swift \\
                  && git commit -m "Resume only after the snapshot lands" && git push origin fix/sync-race --force-with-lease
                """), "Allow Bash")
        }
        #endif
        return ("Bash", .command("swift test --filter SyncEngineTests"), "Allow Bash")
    }
    let transcripts: [SessionKey: [TranscriptMessage]]
    let earlier: [SessionKey: Int]
    let accounts: [RemoteAccount]
    let autopilot: [AutopilotDecision]
    let history: [PastSession]

    /// What Autopilot says about these accounts: a move waiting for a pause, and sessions stopped on Studio's limit.
    var rotation: AutopilotState {
        guard let hold = autopilot.first(where: { $0.kind == .waiting }) else { return AutopilotState(enabled: true, answersRecommended: false) }
        let t = now.timeIntervalSince1970
        return AutopilotState(enabled: true, pending: hold, decisions: autopilot.filter { $0.id != hold.id }, answersRecommended: false, held: [hold],
                              next: [NextMove(id: "work", from: "Work", to: "Personal", atPercent: 95, minutes: 40)],
                              waiting: WaitingSummary(account: "Studio", at: t + 40 * 60), swapAt: 95, followFable: true, fableMode: false)
    }

    var outlook: UsageOutlook {
        UsageOutlook(rooms: [UsageOutlook.Room(provider: .claude, accounts: 3, weeklyLeft: 41, fiveHourLeft: 38, limited: 1,
                                               runsOut: now.timeIntervalSince1970 + 3 * 86_400)])
    }

    enum ID {
        static let syncTest = "6f1c2a90-sync"
        static let cache = "a2b7d1e4-cache"
        static let ship = "c3d4e5f6-ship"
        static let lan = "019a7c22-lan"
        static let postgres = "d9e8f7a6-pg"
        static let spec = "b1a2c3d4-spec"
        static let landing = "e5f6a7b8-landing"
        static let syncRequest = "7d1e0b6a-4c2f-4b8e-9a51-0c3f2e9d8b71"
        static let cacheQuestion = "2c9a5e17-8b3d-4f60-a1c4-6e7b8d9f0a12"
    }

    init(now: Date = .now) {
        self.now = now
        let t = now.timeIntervalSince1970
        func ago(_ minutes: Double) -> Timestamp { t - minutes * 60 }
        func started(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        var live: [RemoteSession] = [
            RemoteSession(id: ID.syncTest, conversationID: ID.syncTest, agent: .claude, title: "Fix the flaky sync test",
                          cwd: "~/Coding/side-a", project: "side-a", branch: "fix/sync-race", accountID: "work", accountName: "Work",
                          model: "opus", effort: "high", status: .waiting, waitingFor: "permission", statusAt: ago(2),
                          step: "Running swift test", context: 84_000, openRequests: [ID.syncRequest], hosted: "sa-side-a-3f2c",
                          abilities: [.transcript, .note, .interrupt, .type, .terminal, .end, .turnDiff, .settingsModel, .settingsEffort, .settingsMode],
                          contextPercent: 42,
                          settings: SessionSettings(model: "claude-opus-5-5", effort: .high, mode: .acceptEdits), turnID: "t-0007",
                          backgroundTasks: 2),
            RemoteSession(id: ID.cache, conversationID: ID.cache, agent: .claude, title: "Cache transcripts on the phone",
                          cwd: "~/Coding/side-a", project: "side-a", branch: "remote/l5-ios", accountID: "personal",
                          accountName: "Personal", model: "sonnet", status: .waiting, waitingFor: "question", statusAt: ago(6),
                          step: "Asked where the cache lives", openRequests: [ID.cacheQuestion],
                          abilities: [.transcript, .note, .followUp]),
            RemoteSession(id: ID.ship, conversationID: ID.ship, agent: .claude, title: "Ship 0.5.37", cwd: "~/Coding/side-a",
                          project: "side-a", branch: "main", accountID: "personal", accountName: "Personal", model: "opus",
                          status: .working, statusAt: ago(14), step: "Editing Island.swift", context: 61_000,
                          mail: MailState(kind: .note, at: ago(1)), abilities: [.transcript, .note, .interrupt, .followUp],
                          abilityReasons: Dictionary(uniqueKeysWithValues: [SessionAbility.settingsModel, .settingsEffort, .settingsMode].map {
                              ($0.rawValue, "Changing settings needs a session Side A hosts.")
                          }),
                          settings: SessionSettings(model: "claude-opus-5-5", effort: .high, mode: .plan)),
            RemoteSession(id: ID.lan, conversationID: ID.lan, agent: .codex, title: "Add LAN mode", cwd: "~/Coding/side-a",
                          project: "side-a", branch: "sidea/lan-mode", worktree: true, accountID: "team", accountName: "Team",
                          model: "gpt-5-codex", status: .working, statusAt: ago(3), step: "Running swift build",
                          hosted: "sa-side-a-91be", abilities: [.transcript, .type, .interrupt, .terminal, .end, .settingsModel, .settingsEffort, .settingsMode],
                          ports: [ListeningPort(port: 5173, process: "vite")], memoryBytes: 1_400_000_000, contextPercent: 18,
                          settings: SessionSettings(model: "gpt-6-sol", effort: .medium, mode: .default),
                          plan: TurnPlan(explanation: "Discovery first, then the pinned certificate.", steps: [
                              TranscriptTodo(text: "Advertise the Mac over Bonjour", status: .completed),
                              TranscriptTodo(text: "Start the listener on the Mac", status: .inProgress, activeForm: "Starting the listener on the Mac"),
                              TranscriptTodo(text: "Pin the self-signed certificate", status: .pending),
                              TranscriptTodo(text: "Test from the phone on the same Wi-Fi", status: .pending),
                          ])),
            RemoteSession(id: ID.postgres, conversationID: ID.postgres, agent: .claude, title: "Move storefront to Postgres 17",
                          cwd: "~/Coding/storefront", project: "storefront", branch: "pg17", accountID: "work", accountName: "Work",
                          model: "sonnet", status: .working, statusAt: ago(31), step: "Running pnpm db:migrate",
                          flag: SessionFlag(kind: .stuck, text: "No progress for 12 minutes"),
                          abilities: [.transcript, .note, .interrupt, .followUp],
                          ports: [ListeningPort(port: 3000, process: "node")], memoryBytes: 2_100_000_000),
            RemoteSession(id: ID.spec, conversationID: ID.spec, agent: .claude, title: "Write the iOS spec", cwd: "~/Coding/side-a",
                          project: "side-a", accountID: "work", accountName: "Work", model: "opus", status: .finished,
                          statusAt: ago(0.3), lastReplyAt: ago(0.3), step: "Wrote docs/remote/ios-app.md",
                          abilities: [.transcript, .followUp]),
            RemoteSession(id: ID.landing, conversationID: ID.landing, agent: .codex, title: "Tighten the landing page copy",
                          cwd: "~/Coding/side-a/site", project: "site", accountID: "team", accountName: "Team", model: "gpt-5",
                          status: .finished, statusAt: ago(9), lastReplyAt: ago(9), step: "Edited 4 files",
                          abilities: [.transcript, .followUp, .compact, .review]),
            RemoteSession(id: "idle-1", agent: .claude, title: "Reproduce the Warp focus bug", project: "side-a", accountName: "Work",
                          model: "opus", status: .idle, statusAt: ago(48), step: "Waiting for you", abilities: [.transcript, .continueOnPhone]),
            RemoteSession(id: "idle-2", agent: .claude, title: "Audit the fleet backups", project: "backups", accountName: "Personal",
                          model: "sonnet", status: .idle, statusAt: ago(95), context: 162_000,
                          flag: SessionFlag(kind: .bloated, text: "Idle · 162k context"), abilities: [.transcript, .continueOnPhone]),
            RemoteSession(id: "idle-3", agent: .codex, title: "Rank-check script", project: "storefront", accountName: "Team",
                          model: "gpt-5", status: .idle, statusAt: ago(130), abilities: [.transcript]),
            RemoteSession(id: "idle-4", agent: .claude, title: "Bump Sparkle to 2.9.6", project: "side-a", accountName: "Work",
                          model: "haiku", status: .idle, statusAt: ago(200), abilities: [.transcript, .continueOnPhone]),
            RemoteSession(id: "idle-5", agent: .claude, title: "Draft the release notes", project: "blog", accountName: "Personal",
                          model: "opus", status: .idle, statusAt: ago(260), abilities: [.transcript, .continueOnPhone]),
            RemoteSession(id: "idle-6", agent: .claude, title: "Fix the uptime prober", project: "uptime", accountName: "Work",
                          model: "sonnet", status: .idle, statusAt: ago(340), abilities: [.transcript, .continueOnPhone]),
        ]
        for index in live.indices where [ID.postgres, ID.spec].contains(live[index].id) {
            live[index].limit = SessionLimit(window: "five_hour", accountID: "studio", until: t + 40 * 60)
        }
        sessions = live

        extras = [
            ID.syncTest: SessionExtras(startedAt: started(38), lastReply: "I found the race. The engine resumes before the snapshot lands."),
            ID.cache: SessionExtras(startedAt: started(22), lastReply: "I can put the cache in two places."),
            ID.ship: SessionExtras(startedAt: started(14), lastReply: "Bumping the version and writing the changelog entry."),
            ID.lan: SessionExtras(startedAt: started(3)),
            ID.postgres: SessionExtras(startedAt: started(52)),
            ID.spec: SessionExtras(startedAt: started(70), lastReply: "The spec is in docs/remote/ios-app.md."),
            ID.landing: SessionExtras(startedAt: started(40), lastReply: "Tightened the hero and the three feature blurbs."),
            "idle-1": SessionExtras(startedAt: started(120)), "idle-2": SessionExtras(startedAt: started(180)),
            "idle-3": SessionExtras(startedAt: started(240)), "idle-4": SessionExtras(startedAt: started(300)),
            "idle-5": SessionExtras(startedAt: started(360)), "idle-6": SessionExtras(startedAt: started(420)),
        ]

        requests = [
            RemoteRequest(id: ID.syncRequest, sessionID: ID.syncTest, agent: .claude, tool: Self.long.tool,
                          action: Self.long.action, headline: Self.long.headline,
                          reason: "Run the sync tests again after the fix", risk: .normal,
                          suggestions: [RemoteSuggestion(id: "9f2e4c1a7b3d5e60", title: "Always allow Bash(swift test:*) in this project")],
                          answers: Self.long.tool == "Edit" ? [.allow, .allowMode, .deny, .terminal] : [.allow, .always, .deny, .terminal],
                          title: "Fix the flaky sync test", project: "side-a", accountName: "Work", arrivedAt: ago(2), gate: .unlock,
                          modes: Self.long.tool == "Edit" ? [.acceptEdits] : nil),
            RemoteRequest(id: ID.cacheQuestion, sessionID: ID.cache, agent: .claude, tool: "AskUserQuestion",
                          action: .question([
                            IslandQuestion(question: "Where should the transcript cache live?", header: "Storage", options: [
                                .init(label: "Caches directory (Recommended)", description: "Purgeable by the system when space runs low"),
                                .init(label: "App Group", description: "Shared with widgets, never purged"),
                                .init(label: "In memory only", description: "Nothing on disk; slower to reopen"),
                            ], multiSelect: false),
                            IslandQuestion(question: "Which sessions should it keep?", header: "Scope", options: [
                                .init(label: "The eight most recent", description: "About 40 MB at most"),
                                .init(label: "Pinned sessions too", description: "Kept until unpinned"),
                            ], multiSelect: true),
                          ]),
                          risk: .low, answers: [.answers, .deny, .terminal], title: "Cache transcripts on the phone",
                          project: "side-a", accountName: "Personal", arrivedAt: ago(6)),
        ]

        transcripts = [
            ID.syncTest: Self.syncTranscript(now: now),
            ID.cache: Self.cacheTranscript(now: now),
            ID.ship: Self.shortTranscript(prompt: "Ship 0.5.37: bump the version, write the changelog, build the release.",
                                          reply: "Bumping the version and writing the changelog entry.", running: "Editing Island.swift", now: now),
            ID.lan: Self.shortTranscript(prompt: "Add LAN mode: Bonjour discovery and a pinned self-signed certificate.",
                                         reply: "I'll start with the listener on the Mac.", running: "Running swift build", now: now),
            ID.postgres: Self.shortTranscript(prompt: "Move storefront to Postgres 17 and run the migrations.",
                                              reply: "Running the migrations against the local database.", running: "Running pnpm db:migrate", now: now),
            ID.spec: Self.specTranscript(now: now),
            ID.landing: Self.shortTranscript(prompt: "Tighten the landing page copy.", reply: "Tightened the hero and the three feature blurbs.",
                                             running: nil, now: now),
        ]
        earlier = [ID.syncTest: 18]

        let fiveHour = 5 * 3600.0
        accounts = [
            RemoteAccount(id: "work", name: "Work", email: "alex@work.example", provider: .claude, ready: true, active: true,
                          usage: AccountUsage(windows: [
                            UsageWindow(id: "five_hour", label: "5-hour", percent: 82, resetsAt: t + 2 * 3600 + 14 * 60),
                            UsageWindow(id: "seven_day", label: "Weekly", percent: 41, resetsAt: t + 4 * 86_400),
                            UsageWindow(id: "model:fable", label: "Weekly Fable", percent: 63, resetsAt: t + 4 * 86_400),
                          ], capacity: 20), readAt: ago(2), sessions: 3, priority: .normal, allowAuto: true, limited: false, fableOut: false),
            RemoteAccount(id: "personal", name: "Personal", email: "alex@personal.example", provider: .claude, ready: true,
                          usage: AccountUsage(windows: [
                            UsageWindow(id: "five_hour", label: "5-hour", percent: 12, resetsAt: t + fiveHour - 600),
                            UsageWindow(id: "seven_day", label: "Weekly", percent: 8, resetsAt: t + 6 * 86_400),
                          ], capacity: 5), readAt: ago(4), sessions: 2, priority: .first, allowAuto: true, limited: false, fableOut: false,
                          issue: AccountIssue(kind: .signInEnds, endsAt: t + 2 * 86_400)),
            RemoteAccount(id: "studio", name: "Studio", email: "alex@studio.example", provider: .claude, ready: true,
                          usage: AccountUsage(windows: [
                            UsageWindow(id: "five_hour", label: "5-hour", percent: 97, resetsAt: t + 40 * 60),
                            UsageWindow(id: "seven_day", label: "Weekly", percent: 76, resetsAt: t + 2 * 86_400),
                          ], stale: true, capacity: 5), readAt: ago(42), sessions: 0, priority: .last, allowAuto: true, limited: true, fableOut: false,
                          backAt: t + 40 * 60),
            RemoteAccount(id: "team", name: "Team", email: "alex@team.example", provider: .codex, ready: true, active: true,
                          usage: AccountUsage(windows: [
                            UsageWindow(id: "five_hour", label: "5-hour", percent: 30, resetsAt: t + 3 * 3600),
                            UsageWindow(id: "seven_day", label: "Weekly", percent: 55, resetsAt: t + 3 * 86_400),
                          ]), readAt: ago(1), sessions: 2, priority: .normal, allowAuto: true, limited: false, fableOut: false),
        ]

        autopilot = [
            AutopilotDecision(id: "a2", at: ago(25), kind: .waiting, title: "Waiting for a pause",
                              reason: "Fix the flaky sync test is mid-step", from: "Work", to: "Personal",
                              sessions: [AutopilotDecision.Moved(sessionID: ID.syncTest, title: "Fix the flaky sync test")]),
            AutopilotDecision(id: "a1", at: ago(180), kind: .moved, title: "Work → Personal",
                              reason: "5-hour 96%", from: "Work", to: "Personal",
                              sessions: [AutopilotDecision.Moved(sessionID: ID.ship, title: "Ship 0.5.37"),
                                         AutopilotDecision.Moved(sessionID: ID.cache, title: "Cache transcripts on the phone")]),
        ]

        history = [
            PastSession(id: "h1", agent: .claude, title: "Hold the Running list still", project: "side-a", cwd: "~/Coding/side-a", branch: "main",
                        lastAt: ago(60 * 20), snippet: "Order changes are held while a touch is down"),
            PastSession(id: "h2", agent: .claude, title: "Open the session's own Warp tab", project: "side-a", cwd: "~/Coding/side-a", branch: "main",
                        lastAt: ago(60 * 6), snippet: "Warp's focus link opens the exact tab"),
            PastSession(id: "h3", agent: .codex, title: "Rank-check script", project: "storefront", cwd: "~/Coding/storefront", branch: "rank",
                        lastAt: ago(60 * 30), snippet: "pnpm rank:check --region west"),
            PastSession(id: "h4", agent: .claude, title: "Restore the uptime prober", project: "uptime", cwd: "~/Coding/uptime", branch: "main",
                        lastAt: ago(60 * 48), snippet: "The mini's launchd job lost its PATH"),
            PastSession(id: "h5", agent: .claude, title: "Write the October update", project: "blog", cwd: "~/Coding/blog", lastAt: ago(60 * 72),
                        snippet: "Power rankings with the group-chat quotes"),
        ]
    }

    // MARK: Transcripts

    private static func syncTranscript(now: Date) -> [TranscriptMessage] {
        let t = now.timeIntervalSince1970
        let yesterday = t - 22 * 3600
        var seq = 18
        func next() -> Int { defer { seq += 1 }; return seq }
        func tool(_ id: String, _ name: String, _ summary: String, _ action: IslandAction?, at: Timestamp, took: Double,
                  status: TranscriptTool.Status = .ok, output: String? = nil, diffs: [FileDiff] = [], images: [ImageRef] = []) -> TranscriptTool {
            TranscriptTool(id: id, name: name, summary: summary, action: action, status: status, startedAt: at,
                           endedAt: status == .running ? nil : at + took, output: output, diffs: diffs, images: images)
        }

        let exploreStart = yesterday + 20
        let explore: [TranscriptTool] = [
            tool("s1", "Thinking", "", nil, at: exploreStart, took: 3,
                 output: "The test fails about one run in five. That smells like ordering, not logic. I should look at where the engine resumes after a reconnect and whether the snapshot can arrive late."),
            tool("s2", "Grep", "resume(", .search("resume( in Sources"), at: exploreStart + 3, took: 0.2, output: "Sources/SyncEngine.swift:118\nSources/SyncEngine.swift:204\nTests/SyncEngineTests.swift:61"),
            tool("s3", "Read", "Sources/SyncEngine.swift", .read(path: "/Users/alex/Coding/side-a/Sources/SyncEngine.swift"), at: exploreStart + 4, took: 0.4,
                 output: "112  func reconnect() async {\n113      socket = makeSocket()\n114      await socket.open()\n115  \n116      // Replay from the last sequence we saw.\n117      let seq = lastSeq\n118      resume()\n119      try? await socket.send(.hello(lastSeq: seq))\n120  }"),
            tool("s4", "Read", "Tests/SyncEngineTests.swift", .read(path: "/Users/alex/Coding/side-a/Tests/SyncEngineTests.swift"), at: exploreStart + 5, took: 0.3),
            tool("s5", "Glob", "**/*Snapshot*.swift", .search("**/*Snapshot*.swift"), at: exploreStart + 6, took: 0.1, output: "Sources/Snapshot.swift\nSources/SnapshotStore.swift"),
            tool("s6", "Read", "Sources/SnapshotStore.swift", .read(path: "/Users/alex/Coding/side-a/Sources/SnapshotStore.swift"), at: exploreStart + 7, took: 0.3),
            tool("s7", "Bash", "swift test --filter SyncEngineTests 2>&1 | tail -20", .command("swift test --filter SyncEngineTests 2>&1 | tail -20"),
                 at: exploreStart + 9, took: 41, status: .failed,
                 output: "Test Suite 'SyncEngineTests' started.\nTest Case 'testReconnectReplaysFromLastSeq' passed (0.412 seconds).\nTest Case 'testSnapshotBeforeResume' failed (1.204 seconds).\n  XCTAssertEqual failed: (\"41\") is not equal to (\"42\")\nExecuted 12 tests, with 1 failure (0 unexpected) in 6.881 seconds"),
            tool("s8", "Thinking", "", nil, at: exploreStart + 52, took: 4,
                 output: "So the snapshot assertion is what fails. resume() runs before the snapshot lands, so the store applies event 42 to a snapshot at 40 and drops 41."),
            tool("s9", "Grep", "applySnapshot", .search("applySnapshot"), at: exploreStart + 57, took: 0.2),
            tool("s10", "Read", "Sources/EventStore.swift", .read(path: "/Users/alex/Coding/side-a/Sources/EventStore.swift"), at: exploreStart + 58, took: 0.3),
            tool("s11", "Bash", "git log --oneline -5 -- Sources/SyncEngine.swift", .command("git log --oneline -5 -- Sources/SyncEngine.swift"), at: exploreStart + 60, took: 0.3,
                 output: "b6748e1 Open the session's own Warp tab\n84647a4 Hold the Running list still\n6ac4f9d Show Claude's questions one at a time"),
            tool("s12", "mcp__xcode__screenshot", "Simulator screenshot", .mcp(server: "xcode", tool: "screenshot", arguments: "{}"), at: exploreStart + 62, took: 1.6,
                 images: [ImageRef(id: "demo-sim-1", mime: "image/png", bytes: 1_240_000, width: 1179, height: 2556, source: .mcp, name: "simulator.png"),
                          ImageRef(id: "demo-sim-2", mime: "image/png", bytes: 980_000, width: 1179, height: 2556, source: .mcp, name: "after-reconnect.png")]),
            tool("s13", "Read", "Sources/Outbox.swift", .read(path: "/Users/alex/Coding/side-a/Sources/Outbox.swift"), at: exploreStart + 65, took: 0.3),
            tool("s14", "Task", "Check other callers of resume()", .other(tool: "Task", arguments: "{}"), at: exploreStart + 66, took: 6),
        ]

        let fix = FileDiff(path: "/Users/alex/Coding/side-a/Sources/SyncEngine.swift", change: .modified, additions: 4, deletions: 2, hunks: [
            DiffHunk(oldStart: 112, oldCount: 9, newStart: 112, newCount: 11, lines: [
                " func reconnect() async {",
                "     socket = makeSocket()",
                "     await socket.open()",
                " ",
                "     // Replay from the last sequence we saw.",
                "     let seq = lastSeq",
                "-    resume()",
                "-    try? await socket.send(.hello(lastSeq: seq))",
                "+    try? await socket.send(.hello(lastSeq: seq))",
                "+    // Resume only once the snapshot or the replay has landed,",
                "+    // so no event applies to an older snapshot.",
                "+    await snapshot.landed()",
                "+    resume()",
                " }",
            ]),
        ])

        let liveStart = t - 150
        return splittingThoughts(first: 18, [
            TranscriptMessage(seq: next(), uuid: "u1", role: .user, at: yesterday,
                              text: "The sync test fails about 1 in 5 runs on CI. Can you find out why and fix it? Here's what the simulator showed.",
                              images: [ImageRef(id: "demo-pasted-1", mime: "image/png", bytes: 412_000, width: 1179, height: 2556, source: .pasted, name: "IMG_2041.png")]),
            TranscriptMessage(seq: next(), uuid: "t1", role: .tools, at: exploreStart, tools: explore),
            TranscriptMessage(seq: next(), uuid: "a1", role: .assistant, at: exploreStart + 72, model: "opus",
                              text: """
                              I found the race. The engine **resumes before the snapshot lands**, so when the reconnect replay is slow, event 42 applies to a snapshot at 40 and event 41 is dropped.

                              ### The fix

                              1. Send `hello` first, then wait for the snapshot or the replay.
                              2. Call `resume()` only after `snapshot.landed()` returns.
                              3. Add a test that delays the snapshot by 200 ms.

                              Nothing else calls `resume()` outside `reconnect()`, so the change stays in one place.
                              """),
            TranscriptMessage(seq: next(), uuid: "t2", role: .tools, at: exploreStart + 80, tools: [
                tool("e1", "Edit", "Sources/SyncEngine.swift", .edit(path: "/Users/alex/Coding/side-a/Sources/SyncEngine.swift", removed: "resume()", added: "await snapshot.landed()"),
                     at: exploreStart + 80, took: 0.4, diffs: [fix]),
            ]),
            TranscriptMessage(seq: next(), uuid: "a2", role: .assistant, at: exploreStart + 84, model: "opus",
                              text: """
                              Here's the new test. It delays the snapshot so the old order would fail every time:

                              ```swift
                              func testSnapshotBeforeResume() async throws {
                                  let socket = FakeSocket(snapshotDelay: .milliseconds(200))
                                  let engine = SyncEngine(socket: socket)
                                  await engine.reconnect()
                                  socket.emit(.event(seq: 41))
                                  socket.emit(.event(seq: 42))
                                  let seen = await engine.store.sequences
                                  XCTAssertEqual(seen, [40, 41, 42])
                              }
                              ```

                              | Run | Before | After |
                              |---|---|---|
                              | Local, 50× | 9 failures | 0 failures |
                              | CI, 20× | 4 failures | not run yet |
                              """),
            TranscriptMessage(seq: next(), uuid: "u2", role: .user, at: t - 200, text: "Looks right. Run the suite again and push if it's green."),
            TranscriptMessage(seq: next(), uuid: "t3", role: .tools, at: liveStart, tools: [
                tool("l1", "Thinking", "", nil, at: liveStart, took: 4,
                     output: "Run only the sync tests first; the full suite takes four minutes."),
                tool("l2", "Grep", "\"testSnapshotBeforeResume\"", .search("testSnapshotBeforeResume"), at: liveStart + 5, took: 0.2),
                tool("l3", "Bash", "swift test --filter SyncEngineTests", .command("swift test --filter SyncEngineTests"),
                     at: t - 120, took: 0, status: .running),
            ]),
        ])
    }

    /// The fixtures above write thinking inline as a "Thinking" step for readability; on the wire
    /// it's its own message with role `thinking`. Splits them out and numbers `seq` densely.
    private static func splittingThoughts(first: Int, _ messages: [TranscriptMessage]) -> [TranscriptMessage] {
        var result: [TranscriptMessage] = []
        func add(_ role: TranscriptRole, uuid: String, at: Timestamp?, model: String? = nil, text: String? = nil,
                 tools: [TranscriptTool] = [], images: [ImageRef] = [], durationMS: Int? = nil) {
            result.append(TranscriptMessage(seq: first + result.count, uuid: uuid, role: role, at: at, model: model, text: text,
                                            tools: tools, images: images, durationMS: durationMS))
        }
        for message in messages {
            guard message.role == .tools else {
                add(message.role, uuid: message.uuid, at: message.at, model: message.model, text: message.text, images: message.images)
                continue
            }
            var pending: [TranscriptTool] = []
            func flush() {
                guard !pending.isEmpty else { return }
                add(.tools, uuid: message.uuid, at: pending[0].startedAt, tools: pending)
                pending = []
            }
            for tool in message.tools {
                if tool.name == "Thinking" {
                    flush()
                    add(.thinking, uuid: message.uuid, at: tool.startedAt, text: tool.output,
                        durationMS: tool.duration.map { Int($0 * 1000) })
                } else {
                    pending.append(tool)
                }
            }
            flush()
        }
        return result
    }

    private static func cacheTranscript(now: Date) -> [TranscriptMessage] {
        let t = now.timeIntervalSince1970
        return [
            TranscriptMessage(seq: 0, uuid: "c-u1", role: .user, at: t - 22 * 60,
                              text: "Cache transcript pages on the phone so a session opens instantly, even offline."),
            TranscriptMessage(seq: 1, uuid: "c-t1", role: .tools, at: t - 21 * 60, tools: [
                TranscriptTool(id: "c1", name: "Read", summary: "docs/remote/ios-app.md", action: .read(path: "/Users/alex/Coding/side-a/docs/remote/ios-app.md"),
                               status: .ok, startedAt: t - 21 * 60, endedAt: t - 21 * 60 + 0.5),
                TranscriptTool(id: "c2", name: "Write", summary: "notes/cache-plan.md", action: .write(path: "/Users/alex/Coding/side-a/notes/cache-plan.md", content: String(repeating: "x", count: 3170)),
                               status: .ok, startedAt: t - 20 * 60, endedAt: t - 20 * 60 + 0.3),
            ]),
            TranscriptMessage(seq: 2, uuid: "c-a1", role: .assistant, at: t - 7 * 60, model: "sonnet",
                              text: "I wrote the plan to a file. The store keeps the eight most recent sessions in memory and pages on disk, keyed by Mac and session.\n\nI can put the cache in two places, and there's a second choice about scope."),
        ]
    }

    private static func specTranscript(now: Date) -> [TranscriptMessage] {
        let t = now.timeIntervalSince1970
        return [
            TranscriptMessage(seq: 0, uuid: "p-u1", role: .user, at: t - 70 * 60, text: "Write the iOS app spec for Side A Remote."),
            TranscriptMessage(seq: 1, uuid: "p-t1", role: .tools, at: t - 69 * 60, tools: [
                TranscriptTool(id: "p1", name: "Read", summary: "docs/remote.md", action: .read(path: "/Users/alex/Coding/side-a/docs/remote.md"),
                               status: .ok, startedAt: t - 69 * 60, endedAt: t - 69 * 60 + 0.4),
                TranscriptTool(id: "p2", name: "WebFetch", summary: "developer.apple.com/design", action: .fetch("https://developer.apple.com/design/human-interface-guidelines/"),
                               status: .ok, startedAt: t - 68 * 60, endedAt: t - 68 * 60 + 2.1),
            ]),
            TranscriptMessage(seq: 2, uuid: "p-a1", role: .assistant, at: t - 20, model: "opus",
                              text: "The spec is in `docs/remote/ios-app.md`: platform, project, state, every screen, notifications, motion and tokens, with a build order per milestone."),
        ]
    }

    static func shortTranscript(prompt: String, reply: String, running: String?, now: Date) -> [TranscriptMessage] {
        let t = now.timeIntervalSince1970
        var messages = [
            TranscriptMessage(seq: 0, uuid: UUID().uuidString, role: .user, at: t - 600, text: prompt),
            TranscriptMessage(seq: 1, uuid: UUID().uuidString, role: .assistant, at: t - 560, model: "opus", text: reply),
        ]
        if let running {
            let command = running.replacingOccurrences(of: "Running ", with: "")
            let isCommand = running.hasPrefix("Running")
            messages.append(TranscriptMessage(seq: 2, uuid: UUID().uuidString, role: .tools, at: t - 90, tools: [
                TranscriptTool(id: UUID().uuidString, name: isCommand ? "Bash" : "Edit", summary: command,
                               action: isCommand ? .command(command) : .edit(path: "Sources/SideA/Island.swift", removed: "", added: ""),
                               status: .running, startedAt: t - 90),
            ]))
        }
        return messages
    }
}
