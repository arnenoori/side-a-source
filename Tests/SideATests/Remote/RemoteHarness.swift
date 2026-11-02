import CryptoKit
import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import SideARemoteKit
import Testing

/// A Mac to pair a phone or the Simulator with, end to end: the real listener, routes, pairing and events over the
/// demo's sessions, a throwaway keychain, and nothing written outside temp folders (hooks stay off in a demo).
/// Run outside `swift test`, whose test process can't be reached from other processes:
///
///     swift build --build-tests
///     scripts/remote-harness.sh            # prints the pairing link, the code and the comparison code
///
/// Settings, all optional: SIDEA_HARNESS_ADDRESSES (comma-separated; default 127.0.0.1 and the LAN address),
/// SIDEA_HARNESS_PORT (any port from 1024; default 47900, which the dev app uses too),
/// SIDEA_HARNESS_CONFIRM (pair, the default, or mismatch), SIDEA_HARNESS_SECONDS (default 1800),
/// SIDEA_HARNESS_OUT (a file for the invitation as JSON), SIDEA_HARNESS_SCENE=1 (open requests at every gate, a question
/// and a plan, reopened a few seconds after the last is answered; a finished turn; transcripts with tools, an image and
/// a diff for the demo's Claude sessions; sixty past conversations across five projects, one forked twice),
/// SIDEA_HARNESS_ANSWER_AFTER=<seconds> (any request open that long is denied from the Mac, so the phone sees it
/// answered elsewhere), SIDEA_HARNESS_STATE=<folder> (pairings, the key and the
/// idempotency records survive restarts with the same folder; the keychain itself stays in ~/scratch/sidea-keychains),
/// SIDEA_HARNESS_CRASH=1 (the first request with an Idempotency-Key runs, then the harness exits before recording its
/// result, so a retry after restarting on the same state gets 409 outcome_unknown), SIDEA_HARNESS_HOSTED=1 (hosted
/// sessions on a private tmux server whose `claude` and `codex` are HostedSessionsTests' fake agent, never the real ones;
/// needs tmux; it also makes real project folders, `side-a` a git repo with two branches and `notes` a plain folder),
/// SIDEA_HARNESS_LOG=<file> (Remote's log, as the app writes ~/Library/Logs/SideA/remote.log),
/// With SIDEA_HARNESS_SCENE, two-way rows too: codex-steer (working; a reply steers, .typed, and submit queue or a
/// follow-up is .queued; interrupt is turnInterrupt and leaves it idle), codex-idle (a reply is .typed and starts a
/// turn), codex-own (no replyTerminal), codex-dropped (flagged unsent until a reply goes through) and claude-inbox
/// (replyInbox, delivery inbox). SIDEA_HARNESS_MAC_ID=<16 hex> and SIDEA_HARNESS_NAME=<name> (a second harness looks like another Mac: hello,
/// invitation m=/n= and confirm signatures all use them).

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SIDEA_REMOTE_HARNESS"] != nil))
func remoteHarness() async throws {
    let env = ProcessInfo.processInfo.environment
    let addresses = env["SIDEA_HARNESS_ADDRESSES"].map { $0.split(separator: ",").map(String.init) }
        ?? ["127.0.0.1"] + RemoteAddresses.current().lan.prefix(1)
    // The argument domain is never saved, so the switch is on for this process only.
    var defaults: [String: Any] = [RemoteController.enabledKey: true]
    if let port = env["SIDEA_HARNESS_PORT"].flatMap(Int.init) { defaults[RemoteController.portKey] = port }
    UserDefaults.standard.setVolatileDomain(defaults, forName: UserDefaults.argumentDomain)
    // Made first: resolving a folder that doesn't exist yet keeps /private, so a second run would name another keychain.
    try env["SIDEA_HARNESS_STATE"].map { try FileManager.default.createDirectory(atPath: $0, withIntermediateDirectories: true) }
    let state = env["SIDEA_HARNESS_STATE"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
    let keychain = try TestKeychain(named: state.map { SHA256.hash(data: Data($0.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined() })
    // A killed run skips deinit; Ctrl-C and SIGTERM still take a throwaway keychain file with them.
    let path = keychain.kept ? nil : keychain.path
    let hosting = env["SIDEA_HARNESS_HOSTED"] != nil ? try HostedFixture() : nil
    defer { hosting?.stop() }
    let stops = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            if let path { try? FileManager.default.removeItem(atPath: path) }
            hosting?.stop()
            exit(0)
        }
        source.resume()
        return source
    }
    defer { stops.forEach { $0.cancel() } }
    let store = AccountStore(demo: true)
    if let hosting {
        let bin = hosting.base.appendingPathComponent("bin")
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("codex"), withDestinationURL: bin.appendingPathComponent("claude"))
        // The live rows hostedRows makes, so resuming a conversation that runs gets 409 alreadyLive as in the app.
        store.hosted = HostedSessions(root: hosting.root, environment: hosting.environment, bridge: hosting.bridge,
                                      live: { [weak store] in store?.sessions.live })
        await store.hosted.install()
    }
    if let log = env["SIDEA_HARNESS_LOG"] { RemoteLog.shared.open(URL(fileURLWithPath: log)) }
    let remote = RemoteController(store: store, keychain: keychain.store, addresses: addresses)
    store.remote = remote
    if let state { remote.idempotencyURL = state.appendingPathComponent("idempotency.sqlite") }
    let scene = env["SIDEA_HARNESS_SCENE"] != nil
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sidea-harness-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    var folders = scene ? HarnessScene.demo : []
    let projects = hosting == nil ? [] : try await HarnessScene.projects(in: hosting!.base)
    folders += projects
    if scene { try HarnessScene.past(home: home, side: projects.first?.1, notes: projects.last?.1) }
    if !folders.isEmpty { try HarnessScene.transcripts(store, home: home, folders: folders) }
    if scene { HarnessScene.set(store) }
    remote.start()
    defer { remote.setEnabled(false) }
    for _ in 0..<250 where !remote.listening.values.contains(.ready) { try await Task.sleep(for: .milliseconds(20)) }
    if hosting != nil {
        // The fake agent registers nothing, so each pane gets the live row Claude's own registry would give it. Wrapped
        // once the server is up: Remote sets its own hook when it starts listening, after the key's first signature.
        let refreshed = store.hosted.onRefresh
        store.hosted.onRefresh = {
            HarnessScene.hostedRows(store)
            refreshed?()
        }
        HarnessScene.hostedRows(store)
    }
    if scene { HarnessScene.twoWay(store) }
    func say(_ line: String) { FileHandle.standardError.write(Data(("HARNESS " + line + "\n").utf8)) }
    say("listening \(remote.listening)")
    if let state { say("state \(state.path), \(remote.devices.devices.count) paired") }
    if env["SIDEA_HARNESS_CRASH"] != nil {
        remote.server?.beforeRecording = { request in
            FileHandle.standardError.write(Data("HARNESS crashing after \(request.method) /\(request.path.joined(separator: "/")) ran, before recording it\n".utf8))
            _exit(70)
        }
    }

    func invite() {
        remote.beginPairing()
        guard let link = remote.qrLink, let pairing = remote.pairing else { return say("no invitation: \(remote.error ?? "no address")") }
        say("link \(link)")
        say("code \(pairing.code.code)")
        if let out = env["SIDEA_HARNESS_OUT"] {
            let invitation = ["link": link, "code": pairing.code.code, "address": remote.endpoints?.tailnet ?? "", "fp": Secret.base64url(remote.spki ?? Data())]
            try? JSONSerialization.data(withJSONObject: invitation, options: [.sortedKeys]).write(to: URL(fileURLWithPath: out))
        }
    }
    invite()
    let decision: PairingSession.Decision = env["SIDEA_HARNESS_CONFIRM"] == "mismatch" ? .mismatch : .pair
    let end = Date().addingTimeInterval(TimeInterval(env["SIDEA_HARNESS_SECONDS"].flatMap(Int.init) ?? 1800))
    var shown: String?
    var devices = remote.devices.devices.map(\.name)
    var emptySince: Date?
    var unlocked = Date()
    let answerAfter = env["SIDEA_HARNESS_ANSWER_AFTER"].flatMap(TimeInterval.init)
    while Date() < end {
        try await Task.sleep(for: .milliseconds(200))
        if Date().timeIntervalSince(unlocked) > 30 {
            keychain.unlock()
            unlocked = Date()
        }
        let now = remote.devices.devices.map(\.name)
        if now != devices {
            say("devices \(now)")
            devices = now
        }
        if let answerAfter, let item = store.island.pending.first(where: { Date().timeIntervalSince($0.arrived) >= answerAfter }) {
            store.island.respond(.deny(nil), item.id, quietly: true, by: .mac)
            say("denied \(item.request.tool) on the Mac after \(Int(answerAfter)) s")
        }
        if scene {
            if !store.island.pending.isEmpty { emptySince = nil } else if emptySince == nil { emptySince = Date() }
            if let since = emptySince, Date().timeIntervalSince(since) > 5 {
                HarnessScene.requests(store)
                emptySince = nil
                say("requests reopened")
            }
        }
        guard let pairing = remote.pairing else { continue }
        switch pairing.phase {
        case .confirm(let attempt) where shown != attempt.id:
            shown = attempt.id
            say("comparison \(attempt.comparison) from \(attempt.request.device.name), key matches: \(attempt.keyMatches); answering \(decision)")
            pairing.decide(decision)
        case .paired(let name):
            say("paired \(name)")
            invite()
        case .stopped(let reason):
            say("stopped: \(reason)")
            invite()
        default: break
        }
    }
}

@MainActor
enum HarnessScene {
    static let cwd = "/Users/demo/side-a"

    static let demo = [("demo-1", cwd), ("demo-2", "/Users/demo/api"), ("demo-3", "/Users/demo/billing")]

    /// A transcript per folder, indexed, so history, search and the project list find them.
    static func transcripts(_ store: AccountStore, home: URL, folders: [(String, String)]) throws {
        for (session, folder) in folders {
            try TranscriptFixture.write(TranscriptFixture.lines(session: session, cwd: folder, day: TranscriptFixture.today), session: session, home: home)
        }
        let index = home.appendingPathComponent("Side A")
        TranscriptFixture.index(home: home, root: index)
        store.sessions.transcriptSource = (home: home, bridge: TranscriptFixture.bridge, python: "/usr/bin/python3", root: index)
    }

    /// Sixty finished conversations across five projects and the last six weeks, so history spans two pages and search has
    /// something to find, and a fork of `past-03` with a fork of its own, for the phone's parent links. Given the hosted
    /// folders, the side-a and notes ones live there, so the phone can resume and fork them.
    static func past(home: URL, side: String? = nil, notes: String? = nil) throws {
        let topics = ["Add CSV export to reports", "Fix the login redirect loop", "Speed up the search index", "Write the release notes",
                      "Move settings to a sheet", "Debug the flaky upload test", "Add dark mode to the dashboard", "Rename the billing tables",
                      "Profile memory on launch", "Retry failed webhooks", "Add a health check endpoint", "Clean up unused assets",
                      "Paginate the activity feed", "Upgrade to Swift 6.2", "Cache avatar images", "Fix timezone math in invoices",
                      "Draft the onboarding copy", "Add keyboard shortcuts", "Split the API client", "Audit the npm dependencies",
                      "Tidy the README", "Add rate limits to login", "Stream large downloads", "Fix the iPad layout",
                      "Track signup conversions", "Make the sidebar resizable", "Lint the shell scripts", "Port the cron jobs",
                      "Fix the off-by-one in paging", "Add a CHANGELOG entry", "Index the archive folder", "Batch email sends",
                      "Explain the auth middleware", "Add tests for refunds", "Migrate to the new router", "Fix the crash on sleep",
                      "Compress the screenshots", "Add Spanish strings", "Find why CI is slow", "Plan the v2 schema"]
        let places = [(side ?? "/Users/demo/side-a", ["main", "feature/export", "fix/island"]), ("/Users/demo/api", ["main", "webhooks"]),
                      ("/Users/demo/billing", ["main", "schema-v2"]), ("/Users/demo/site", ["main"]), (notes ?? "/Users/demo/notes", [nil])]
        let replies = ["Done: the change is in and the tests pass.", "I found the cause in the retry loop and fixed it.",
                       "Here is a plan in three steps before I touch anything.", "That needs a migration; I wrote it and ran it locally.",
                       "I couldn't reproduce it, so I added logging around the failing call."]
        let clock = ISO8601DateFormatter()
        let now = Date()
        func conversation(_ id: String, _ n: Int, at start: Date, inherited: [[String: Any]] = [], fork: [String: String]? = nil,
                          twist: String = "") -> [[String: Any]] {
            let (cwd, branches) = places[n % places.count]
            func entry(_ type: String, _ uuid: String, _ offset: TimeInterval, _ content: [[String: Any]]) -> [String: Any] {
                var line: [String: Any] = ["type": type, "uuid": uuid, "sessionId": id, "timestamp": clock.string(from: start.addingTimeInterval(offset)),
                                           "cwd": cwd, "message": ["role": type, "id": "m-\(uuid)", "model": "claude-opus-5-5", "content": content]]
                if let branch = branches[n % branches.count] { line["gitBranch"] = branch }
                return line
            }
            let copied = inherited.map { $0.merging(["sessionId": id, "forkedFrom": fork ?? [:]]) { _, new in new } }
            return copied + [
                entry("user", "\(id)-u1", 0, [["type": "text", "text": topics[n % topics.count] + (n >= topics.count ? " again" : "") + twist]]),
                entry("assistant", "\(id)-a1", 40, [["type": "text", "text": replies[n % replies.count]]]),
                entry("user", "\(id)-u2", 300, [["type": "text", "text": "Thanks. Now check the \(["tests", "docs", "logs", "build"][n % 4]) for \(topics[(n + 7) % topics.count].lowercased())"]]),
                entry("assistant", "\(id)-a2", 360, [["type": "text", "text": replies[(n + 2) % replies.count]]]),
            ]
        }
        var written: [String: [[String: Any]]] = [:]
        for n in 0..<60 {
            let id = String(format: "past-%02d", n)
            // Newest a few hours ago, oldest about six weeks back.
            written[id] = conversation(id, n, at: now.addingTimeInterval(-Double(n + 1) * 16 * 3600 - Double(n % 3) * 1200))
        }
        let child = conversation("past-03-fork", 3, at: now.addingTimeInterval(-6 * 3600), inherited: written["past-03"]!.prefix(2).map { $0 },
                                 fork: ["sessionId": "past-03", "messageUuid": "past-03-a1"], twist: ", another way")
        written["past-03-fork"] = child
        written["past-03-fork-2"] = conversation("past-03-fork-2", 3, at: now.addingTimeInterval(-2 * 3600), inherited: child.prefix(4).map { $0 },
                                                 fork: ["sessionId": "past-03-fork", "messageUuid": "past-03-fork-a1"],
                                                 twist: ", shorter")
        for (id, lines) in written { try TranscriptFixture.write(lines, session: id, home: home) }
    }

    /// Folders that exist, for New Session: a git repo with a commit on main and a second branch, and a plain folder.
    static func projects(in base: URL) async throws -> [(String, String)] {
        let repo = base.appendingPathComponent("side-a"), notes = base.appendingPathComponent("notes")
        for folder in [repo, notes] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "# Side A\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "Ideas\n".write(to: notes.appendingPathComponent("ideas.md"), atomically: true, encoding: .utf8)
        let environment = ["HOME": base.appendingPathComponent("home").path, "GIT_CONFIG_NOSYSTEM": "1",
                           "GIT_AUTHOR_NAME": "Harness", "GIT_AUTHOR_EMAIL": "harness@example.com",
                           "GIT_COMMITTER_NAME": "Harness", "GIT_COMMITTER_EMAIL": "harness@example.com"]
        for args in [["init", "-q", "-b", "main"], ["add", "."], ["commit", "-q", "-m", "First"], ["branch", "feature/export"]] {
            _ = await HostedSessions.process("/usr/bin/git", ["-C", repo.path] + args, environment: environment, timeout: 10)
        }
        return [("project-1", repo.path), ("project-2", notes.path)]
    }

    private static var pids: [String: Int] = [:]

    static func hostedRows(_ store: AccountStore) {
        let panes = store.hosted.sessions.filter { $0.agent != nil }
        var live = store.sessions.live.filter { row in row.pid < 95_000 || panes.contains { $0.name == row.hosted } }
        for pane in panes where !live.contains(where: { $0.hosted == pane.name }) {
            let pid = pids[pane.name] ?? 95_000 + pids.count
            pids[pane.name] = pid
            let session = pane.sessionID.isEmpty ? "hosted-\(pane.name)" : pane.sessionID
            // A transcript too, as the agent would write one, for history and Restart Fresh's handoff.
            if let source = store.sessions.transcriptSource {
                try? TranscriptFixture.write(TranscriptFixture.lines(session: session, cwd: pane.cwd, day: TranscriptFixture.today), session: session,
                                             home: source.home)
                TranscriptFixture.index(home: source.home, root: source.root)
            }
            live.append(LiveSession(pid: pid, sessionID: session, name: nil,
                                    title: "New session", cost: nil, cwd: pane.cwd, status: "idle", waitingFor: nil,
                                    // No start time: ProcessCheck.maySignal refuses any row without one, so these
                                    // made-up pids can never reach a real process.
                                    since: Date().timeIntervalSince1970, hosted: pane.name,
                                    agent: pane.agent == .codex ? "codex" : "claude"))
        }
        guard live != store.sessions.live else { return }
        store.sessions.live = live
        store.remote.events?.liveChanged()
    }

    /// Two-way rows for the phone: Codex sessions as if reached through its app server (working, idle, one whose
    /// message was dropped) and one it can't reach, and a Claude session started in a terminal with its inbox hook
    /// waiting. Staged on CodexTerminals and ClaudeInbox; no daemon or hook runs behind them.
    static func twoWay(_ store: AccountStore) {
        store.sessions.retainLive("harness")
        let now = Date().timeIntervalSince1970
        let rows: [(Int, String, String, String, String)] = [
            (94001, "codex-steer", "Steer the parser rewrite", "busy", "codex"),
            (94002, "codex-idle", "Codex waiting for a message", "idle", "codex"),
            (94003, "codex-own", "Started outside Codex's shared server", "busy", "codex"),
            (94004, "codex-dropped", "A steer Codex dropped", "idle", "codex"),
            (94005, "claude-inbox", "Claude in a terminal, inbox on", "idle", "claude"),
        ]
        for (pid, id, title, status, agent) in rows where !store.sessions.live.contains(where: { $0.pid == pid }) {
            store.sessions.live.append(LiveSession(pid: pid, sessionID: id, name: nil, title: title, cost: nil, cwd: "/Users/demo/side-a", status: status,
                                                   waitingFor: nil, since: now, agent: agent))
        }
        store.remote.codex.staged = [
            "codex-steer": .init(reach: .attached, status: .working),
            "codex-idle": .init(reach: .attached, status: .idle),
            "codex-own": .init(reach: .own, status: .working),
            "codex-dropped": .init(reach: .attached, status: .idle, unsent: "Also rename the tests"),
        ]
        store.island.installed[.claude] = true
        store.remote.inbox.staged = [94005]
        store.remote.events?.liveChanged()
    }

    static func set(_ store: AccountStore) {
        store.island.installed[.claude] = true
        requests(store)
        store.island.ready = [Island.Ready(finish: IslandFinish(agent: .claude, sessionID: "demo-3", cwd: "/Users/demo/billing", pid: 90003,
                                                                summary: "Moved the billing tables to the new schema; all migrations pass."),
                                           title: "Migrate the billing tables")]
    }

    /// One request at each gate (lock screen, unlock, Face ID), a question and a plan, none with a hook waiting behind it.
    static func requests(_ store: AccountStore) {
        let rule: [String: Any] = ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test:*"]], "behavior": "allow",
                                   "destination": "localSettings"]
        let requests: [(String, [String: Any])] = [
            ("demo-1", ["tool_name": "Read", "tool_input": ["file_path": cwd + "/README.md"]]),
            ("demo-1", ["tool_name": "Bash", "tool_input": ["command": "npm test"], "permission_suggestions": [rule]]),
            ("demo-2", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]]),
            ("demo-2", ["tool_name": "AskUserQuestion", "tool_input": ["questions": [
                ["question": "Which database should the export use?", "header": "Database", "multiSelect": false,
                 "options": [["label": "Postgres (Recommended)", "description": "The main store"], ["label": "SQLite", "description": "A local copy"]]],
                ["question": "Which formats?", "header": "Formats", "multiSelect": true,
                 "options": [["label": "CSV"], ["label": "JSON"], ["label": "Parquet"]]],
            ]]]),
            ("demo-1", ["tool_name": "ExitPlanMode", "tool_input": ["plan": "1. Split IslandView into parts.\n2. Animate the height.\n3. Test it on a notchless display."]]),
        ]
        for (session, body) in requests {
            let message: [String: Any] = ["v": 1, "agent": "claude", "pid": session == "demo-1" ? 90001 : 90002, "slot": "mac",
                                          "request": body.merging(["session_id": session, "cwd": session == "demo-1" ? cwd : "/Users/demo/api"]) { a, _ in a }]
            guard let data = try? JSONSerialization.data(withJSONObject: message), let request = IslandRequest(message: data) else { continue }
            // The demo's live sessions appear once Remote records; these are their titles.
            let title = ["demo-1": "Polish the island transitions", "demo-2": "Fix the flaky upload test"][session] ?? session
            let item = Island.Pending(connection: nil, request: request, title: title, account: nil, handBackAt: nil)
            store.island.pending.append(item)
            store.island.watcher?.requestAdded(item)
        }
    }
}
