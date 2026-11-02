import SideAProtocol
import SideARemoteShared
import SideARemoteKit
import XCTest
@testable import SideARemote

@MainActor
final class LiveTests: XCTestCase {
    private func session(_ id: String, status: SessionStatus = .working, at: Timestamp = 1_000) -> RemoteSession {
        RemoteSession(id: id, agent: .claude, title: id, project: "side-a", status: status, statusAt: at)
    }

    func testReplaceKeepsFirstSeenOrder() {
        let store = SessionsStore([])
        store.replace([session("a", at: 100), session("b", at: 200)], finished: [:], now: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(store.rows(.working).map(\.id), ["b", "a"])
        // A later status change doesn't move a row within its phase.
        store.replace([session("a", at: 900), session("b", at: 200)], finished: [:])
        XCTAssertEqual(store.rows(.working).map(\.id), ["b", "a"])
    }

    func testAnswerGoesToTheMacOnce() {
        let request = DemoData(now: .now).requests[0]
        let store = RequestsStore([request])
        var sent: [RequestID] = []
        store.onAnswer = { request, _, _, _ in sent.append(request.id) }
        store.answer(request.id, .allow(confirmDestructive: false))
        store.answer(request.id, .allow(confirmDestructive: false))
        XCTAssertEqual(sent, [request.id])
        XCTAssertTrue(store.open.isEmpty)
    }

    func testEarlierCountFromFirstSeq() {
        let store = TranscriptStore([:])
        let messages = (40..<45).map { TranscriptMessage(seq: $0, uuid: "\($0)", role: .assistant, at: 0, text: "m") }
        store.set(messages, hasEarlier: true, for: "s")
        XCTAssertEqual(store.earlier["s"], 40)
        store.set(messages, hasEarlier: false, for: "s")
        XCTAssertEqual(store.earlier["s"], 0)
    }

    func testDropReadsAsReconnectingThenOffline() {
        let mac = MacConnection(name: "MacBook Pro", state: .connecting, lastSeen: .now)
        var state = RemoteState()
        state.connection = .live(since: 0)
        let start = Date(timeIntervalSince1970: 1_000)
        mac.apply(state, name: "MacBook Pro", now: start)
        XCTAssertEqual(mac.state, .live)
        state.connection = .offline(retryAt: 0, reason: "closed")
        mac.apply(state, name: "MacBook Pro", now: start.addingTimeInterval(1))
        XCTAssertEqual(mac.state, .reconnecting(since: start.addingTimeInterval(1)))
        mac.apply(state, name: "MacBook Pro", now: start.addingTimeInterval(90))
        XCTAssertEqual(mac.state, .offline(.macUnreachable))
        mac.vpnUp = false
        mac.apply(state, name: "MacBook Pro", now: start.addingTimeInterval(95))
        XCTAssertEqual(mac.state, .offline(.tailscaleOff))
        state.connection = .unpaired
        mac.apply(state, name: "MacBook Pro")
        XCTAssertEqual(mac.state, .offline(.revoked))
    }

    func testAnswerLineFollowsDelivery() {
        let request = DemoData(now: .now).requests[0]
        let store = TranscriptStore([:])
        store.onRetry = { _ in }
        store.record(.allowed, for: request, in: "s")
        XCTAssertEqual(store.answered["s"]?.first?.delivery, .sending)
        store.deliver(request.id, in: "s", .unknown)
        XCTAssertEqual(store.answered["s"]?.first?.delivery, .unknown)

        let demo = TranscriptStore([:])
        demo.record(.allowed, for: request, in: "s")
        XCTAssertEqual(demo.answered["s"]?.first?.delivery, .delivered)
    }

    func testRetryOutcomes() {
        let gone = APIError(code: .requestNotFound, message: "That request isn't open on the Mac any more.", retryable: false)
        XCTAssertEqual(TranscriptStore.Delivery(nil, retried: true), .sending)
        XCTAssertEqual(TranscriptStore.Delivery(.answeredElsewhere(nil), retried: false), .answeredElsewhere)
        XCTAssertEqual(TranscriptStore.Delivery(.answeredElsewhere(nil), retried: true), .delivered)
        XCTAssertEqual(TranscriptStore.Delivery(.failed(gone), retried: false), .failed(gone.message))
        XCTAssertEqual(TranscriptStore.Delivery(.failed(gone), retried: true), .gone)
    }

    func testTailnetAddresses() {
        XCTAssertTrue(Tailscale.isTailnet("100.101.12.4"))
        XCTAssertTrue(Tailscale.isTailnet("macbook.tail1234.ts.net"))
        XCTAssertFalse(Tailscale.isTailnet("100.200.1.1"))
        XCTAssertFalse(Tailscale.isTailnet("192.168.1.20"))
        XCTAssertFalse(Tailscale.isTailnet("127.0.0.1"))
    }

    func testOnlyAPinnedLinkInTheMacsFormPairs() {
        let fragment = "#v=2&a=100.101.12.4:47800&fp=g1deSK0gAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&n=MacBook&m=m1&c=ABCD2345"
        XCTAssertNotNil(PairingLink.invitation(URL(string: "sidea-remote://pair" + fragment)!))
        XCTAssertNotNil(PairingLink.invitation(URL(string: "https://getsidea.com/pair" + fragment)!))
        XCTAssertNotNil(PairingLink.invitation(URL(string: "https://getsidea.com/pair/" + fragment)!))
        XCTAssertNil(PairingLink.invitation(URL(string: "https://getsidea.com/pair/x" + fragment)!))
        // Another host or path carrying the same fragment.
        XCTAssertNil(PairingLink.invitation(URL(string: "https://evil.example/pair" + fragment)!))
        XCTAssertNil(PairingLink.invitation(URL(string: "sidea-remote://session/pair" + fragment)!))
        XCTAssertNil(PairingLink.invitation(URL(string: "http://getsidea.com/pair" + fragment)!))
    }

    func testReviewCodeOpensTheDemoOnlyInAPairingLink() {
        XCTAssertTrue(ReviewDemo.matches(URL(string: "https://getsidea.com/pair#review=GVCDWQ37LE")!))
        XCTAssertTrue(ReviewDemo.matches(URL(string: "https://getsidea.com/pair/#review=gvcdwq37le")!))
        XCTAssertTrue(ReviewDemo.matches(URL(string: "sidea-remote://pair#review=GVCDWQ37LE")!))
        XCTAssertFalse(ReviewDemo.matches(URL(string: "https://evil.example/pair#review=GVCDWQ37LE")!))
        XCTAssertFalse(ReviewDemo.matches(URL(string: "http://getsidea.com/pair#review=GVCDWQ37LE")!))
        XCTAssertFalse(ReviewDemo.matches(URL(string: "https://getsidea.com/pair#review=WRONG12345")!))
        XCTAssertFalse(ReviewDemo.matches(URL(string: "https://evil.example/pair#review=WRONG12345")!))
        XCTAssertFalse(ReviewDemo.matches(URL(string: "sidea-remote://pair")!))
        // A review link is never an invitation.
        XCTAssertNil(PairingLink.invitation(URL(string: "https://getsidea.com/pair#review=WRONG12345")!))
    }

    func testAChangeShowsEveryLineMarked() {
        let text = String(RequestPayload.change(removed: "a\nb", added: "c").characters)
        XCTAssertEqual(text, "- a\n- b\n+ c")
        XCTAssertEqual(String(RequestPayload.change(removed: "", added: "new").characters), "+ new")
    }

    func testAgentTextCantOpenAPairingLink() {
        for link in ["sidea-remote://pair#v=2", "https://getsidea.com/pair#v=2&a=1.2.3.4&fp=x&m=y&c=z", "https://getsidea.com/pair/#review=X",
                     "HTTPS://GetSideA.com/PAIR#v=2", "https://getsidea.com./pair#v=2", "https://getsidea.com/%70air#v=2",
                     "https://getsidea.com/x/../pair#v=2", "http://getsidea.com/pair", "https://www.getsidea.com/pair", "tel:123"] {
            XCTAssertFalse(AgentLink.opens(URL(string: link)!), link)
        }
        for link in ["https://example.com/pair", "https://getsidea.com/", "https://getsidea.com/pairing", "http://localhost:3000"] {
            XCTAssertTrue(AgentLink.opens(URL(string: link)!), link)
        }
        let blocks = MarkdownParser.blocks("[a](https://getsidea.com/pair#v=2) [b](sidea-remote://pair#v=2) [c](https://example.com)")
        let links = blocks.flatMap { $0.text.runs.compactMap(\.link) }
        XCTAssertEqual(links, [URL(string: "https://example.com")!])
    }

    func testAReviewLinkAsksFirstWhenAMacIsPaired() {
        let review = URL(string: "https://getsidea.com/pair#review=GVCDWQ37LE")!
        XCTAssertEqual(LinkAction.of(review, pairedMacs: 1), .confirmDemo)
        XCTAssertEqual(LinkAction.of(review, pairedMacs: 0), .openDemo)
        XCTAssertEqual(LinkAction.of(URL(string: "sidea-remote://accounts")!, pairedMacs: 1), .deep(.accounts))
    }

    func testRequestTextShowsWhatsHidden() {
        XCTAssertEqual(RequestText.visible("a\u{202E}b"), "a\\u{202E}b")
        XCTAssertEqual(RequestText.visible("a\u{200B}b\u{2066}c\u{7}d\u{FEFF}"), "a\\u{200B}b\\u{2066}c\\u{0007}d\\u{FEFF}")
        XCTAssertEqual(RequestText.visible("a\r\nb"), "a\\r\nb")
        XCTAssertEqual(RequestText.visible("a\u{2028}b"), "a\\u{2028}b")
        XCTAssertEqual(RequestText.visible("\u{E0041}"), "\\u{E0041}")
        for plain in ["swift test", "a\tb\nc", "café 日本語", "👩‍💻 ❤️‍🔥 ok"] {
            XCTAssertFalse(RequestText.hasEscapes(plain), plain)
            XCTAssertEqual(RequestText.visible(plain), plain)
        }
        XCTAssertTrue(RequestText.hasEscapes("a\u{200D}b"))
        XCTAssertEqual(String(RequestPayload.change(removed: "", added: "a\r\nb").characters), "+ a\\r\n+ b")
        XCTAssertEqual(String(RequestPayload.patch("+a\u{202E}b").characters), "+a\\u{202E}b")
    }

    func testBlanksOfAnyKindShowAsARun() {
        for blank in ["\u{2003}", "\u{A0}", "\u{2800}", "\t", "\u{3000}", " "] {
            let text = "ls" + String(repeating: blank, count: 400) + "; python3 x"
            XCTAssertTrue(RequestText.padded(text), blank)
            XCTAssertTrue(RequestText.hasEscapes(text), blank)
            XCTAssertFalse(RequestText.fitsCard(text), blank)
            XCTAssertTrue(RequestText.visible(text).hasSuffix("×400; python3 x"), blank)
        }
        XCTAssertFalse(RequestText.padded("a  b\tc\u{A0}d"))
        XCTAssertTrue(RequestText.fitsCard("swift test"))
        XCTAssertFalse(RequestText.fitsCard("ls " + String(repeating: "x", count: 500)))
        XCTAssertFalse(RequestText.fitsCard("a" + String(repeating: "\n", count: 6) + "b"))
    }

    func testARowNeverAllowsWhatNeededAnEscape() {
        func request(_ action: IslandAction) -> RemoteRequest {
            RemoteRequest(id: "r", sessionID: "s", agent: .claude, tool: "Bash", action: action, headline: "Allow Bash", risk: .normal,
                          answers: [.allow, .deny], title: "t", arrivedAt: 0)
        }
        XCTAssertFalse(request(.command("make\r\nmake install")).fitsRow)
        XCTAssertFalse(request(.command("ls\u{202E}")).fitsRow)
        XCTAssertFalse(request(.command("ls\u{200B} -la")).fitsRow)
        XCTAssertFalse(request(.read(path: "/a\u{202E}b.txt")).fitsRow)
        XCTAssertFalse(request(.read(path: "/a\r\nb.txt")).fitsRow)
        XCTAssertTrue(request(.read(path: "/a.txt")).fitsRow)
    }

    func testALockedAppSignsAndAnswersNothing() async {
        let store = RequestsStore([RemoteRequest(id: "r", sessionID: "s", agent: .claude, tool: "Bash", action: .command("ls"), headline: "Allow Bash",
                                                 risk: .normal, answers: [.allow, .deny], title: "t", arrivedAt: 0)])
        var answered = 0
        store.onAnswer = { _, _, _, _ in answered += 1 }
        DeviceKeys.appLocked = true
        defer { DeviceKeys.appLocked = false }
        store.answer("r", .allow(confirmDestructive: false))
        XCTAssertEqual(answered, 0)
        XCTAssertNotNil(store.request("r"))
        let signed = await DeviceKeys.header(.unlock, macID: "locked-mac", deviceID: "d", purpose: .allow, subject: "s")
        XCTAssertNil(signed)
    }

    func testTheCoverIsUpWheneverTheAppIsntActive() {
        let lock = AppLock(arguments: ["--no-lock"])
        XCTAssertFalse(lock.covered)
        lock.phase(.inactive)
        XCTAssertTrue(lock.covered)
        lock.phase(.active)
        XCTAssertFalse(lock.covered)
        lock.phase(.background)
        XCTAssertTrue(lock.covered)
        lock.phase(.active)
        XCTAssertFalse(lock.covered)
    }

    func testTheLockSitsAboveEverySheet() throws {
        let lock = AppLock(arguments: ["--no-lock"])
        lock.phase(.inactive)
        LockWindow.shared.update(lock)
        let window = try XCTUnwrap(LockWindow.shared.window)
        XCTAssertFalse(window.isHidden)
        XCTAssertGreaterThan(window.windowLevel, UIWindow.Level.alert)
        lock.phase(.active)
        LockWindow.shared.update(lock)
        XCTAssertNil(LockWindow.shared.window)
    }

    /// A row's swipe allows only what its two lines show whole; an edit's change is never on the row.
    func testRowAllowsOnlyWhatItShows() {
        func request(_ action: IslandAction) -> RemoteRequest {
            RemoteRequest(id: "r", sessionID: "s", agent: .claude, tool: "Bash", action: action, headline: "Allow Bash", risk: .normal,
                          answers: [.allow, .deny], title: "t", arrivedAt: 0)
        }
        XCTAssertTrue(request(.command("swift test")).fitsRow)
        XCTAssertFalse(request(.command(String(repeating: "x", count: 37))).fitsRow)
        XCTAssertFalse(request(.command("make\nmake install")).fitsRow)
        XCTAssertFalse(request(.edit(path: "/a.swift", removed: "x", added: "y")).fitsRow)
        XCTAssertFalse(RemoteRequest(id: "r", agent: .claude, tool: "Bash", action: .command("ls"), risk: .normal, answers: [.allow],
                                     title: "t", arrivedAt: 0, truncated: true).fitsRow)
    }

    func testTheDemosTurnDiffGathersItsTranscriptsDiffs() async throws {
        let tools = MacTools(demo: .init(options: OptionsList(agents: []), projects: []))
        let file = FileDiff(path: "/a.swift", change: .modified, additions: 1, deletions: 1, hunks: [])
        let edit = TranscriptTool(id: "e", name: "Edit", summary: "a.swift", action: .edit(path: "/a.swift", removed: "x", added: "y"),
                                  status: .ok, startedAt: 0, diffs: [file])
        let diff = try await tools.turnDiff("s", turn: "t", demo: [TranscriptMessage(seq: 1, uuid: "u", role: .tools, at: 0, tools: [edit])])
        XCTAssertEqual(diff.files, [file])
        XCTAssertNotNil(diff.note)
    }

    func testModesFollowTheMacsChip() {
        XCTAssertEqual(PermissionMode.offered(.claude, current: .acceptEdits), [.default, .acceptEdits, .plan, .auto, .bypassPermissions])
        XCTAssertEqual(PermissionMode.offered(.codex, current: nil), [.default, .plan])
        // A mode the Mac's list doesn't offer still shows, checked, at the end.
        XCTAssertEqual(PermissionMode.offered(.claude, current: .dontAsk).last, .dontAsk)
        XCTAssertEqual(PermissionMode.acceptEdits.title, "Accept edits")
        XCTAssertEqual(PermissionMode(rawValue: "yolo").title, "yolo")
    }

    func testAModeChangedHereShowsUntilTheRowSaysSo() async throws {
        let tools = MacTools(demo: .init(options: OptionsList(agents: []), projects: []))
        let row = RemoteSession(id: "s", agent: .codex, title: "s", project: "p", status: .idle, settings: SessionSettings(mode: .default))
        let result = try await tools.change(row, SettingsChange(mode: .plan), title: "Plan")
        XCTAssertTrue(result.nextTurn)
        XCTAssertEqual(tools.mode(of: row), .plan)
        var state = RemoteState()
        state.sessions["s"] = row
        tools.apply(state)
        XCTAssertEqual(tools.mode(of: row), .plan)
        state.sessions["s"] = RemoteSession(id: "s", agent: .codex, title: "s", project: "p", status: .idle, settings: SessionSettings(mode: .plan))
        tools.apply(state)
        XCTAssertNil(tools.changed["s"])
    }

    func testSettingsChangedHereClearFieldByField() async throws {
        let tools = MacTools(demo: .init(options: OptionsList(agents: []), projects: []))
        let row = RemoteSession(id: "s", agent: .claude, title: "s", project: "p", model: "opus", status: .idle,
                                settings: SessionSettings(model: "claude-opus-5-5", effort: .high, mode: .default))
        _ = try await tools.change(row, SettingsChange(model: "claude-sonnet-5-5"), title: "Sonnet 5.5")
        _ = try await tools.change(row, SettingsChange(effort: .low), title: "Low effort")
        XCTAssertEqual(tools.settings(of: row), SessionSettings(model: "claude-sonnet-5-5", effort: .low, mode: .default))
        // The row says the model first; the effort waits on.
        var state = RemoteState()
        state.sessions["s"] = RemoteSession(id: "s", agent: .claude, title: "s", project: "p", status: .idle,
                                            settings: SessionSettings(model: "claude-sonnet-5-5", effort: .high, mode: .default))
        tools.apply(state)
        XCTAssertEqual(tools.changed["s"], SessionSettings(effort: .low))
        // A model the list doesn't have still shows, first, by its short name.
        XCTAssertEqual(tools.models(for: state.sessions["s"]!).first?.title, "Sonnet 5.5")
        XCTAssertEqual(ModelName.short("claude-opus-5-5-20260101"), "Opus 5.5")
        XCTAssertEqual(ModelName.short("gpt-6.1-sol"), "GPT-6.1 Sol")
    }

    func testAllowAndAcceptEditsFollowsTheMac() throws {
        func request(modes: [PermissionMode]?, answers: Set<AnswerKind> = [.allow, .allowMode, .deny], gate: AllowGate = .unlock) -> RemoteRequest {
            RemoteRequest(id: "r", sessionID: "s", agent: .claude, tool: "Edit", action: .edit(path: "/a.swift", removed: "x", added: "y"),
                          risk: .normal, answers: answers, title: "t", arrivedAt: 0, gate: gate, modes: modes)
        }
        XCTAssertEqual(request(modes: [.acceptEdits]).switchMode, .acceptEdits)
        XCTAssertEqual(request(modes: [.acceptEdits]).switchTitle, "Allow + Accept Edits")
        XCTAssertNil(request(modes: nil).switchMode)
        XCTAssertNil(request(modes: [.acceptEdits], answers: [.allow, .deny]).switchMode)
        // Face ID's Allow and a mode that raises stay off the card.
        XCTAssertNil(request(modes: [.acceptEdits], gate: .biometric).switchMode)
        XCTAssertNil(request(modes: [.bypassPermissions]).switchMode)

        let store = RequestsStore([request(modes: [.acceptEdits])])
        var sent: PermissionMode?
        var line: String?
        store.onAnswer = { _, _, mode, _ in sent = mode }
        store.onResolve = { _, outcome in line = outcome.line }
        store.answer("r", .allow(confirmDestructive: false), mode: .acceptEdits)
        XCTAssertEqual(sent, .acceptEdits)
        XCTAssertEqual(line, "Allowed · edits won't ask")
        XCTAssertEqual(try LiveLink.subject("r", .allow(confirmDestructive: false), mode: .acceptEdits), "r:allowMode:acceptEdits")
        XCTAssertEqual(try LiveLink.subject("r", .allow(confirmDestructive: false), mode: nil), "r:allow")
    }

    func testACutMessageLoadsWholeOnce() async throws {
        let cut = TranscriptMessage(seq: 3, uuid: "a", role: .assistant, text: "First part", textTruncated: true)
        let full = TranscriptMessage(seq: 3, uuid: "a", role: .assistant, text: "First part and the rest")
        let store = TranscriptStore(["s": [cut]])
        var calls = 0
        var fails = true
        store.onLoadWhole = { _, _ in
            calls += 1
            if fails { throw URLError(.timedOut) }
            return full
        }
        store.loadWhole(cut, in: "s")
        store.loadWhole(cut, in: "s")
        for _ in 0..<50 where store.wholeLoad(cut, in: "s") == .loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.wholeLoad(cut, in: "s"), .failed)
        // A failure waits for Try Again.
        store.loadWhole(cut, in: "s")
        XCTAssertEqual(calls, 1)
        fails = false
        store.loadWhole(cut, in: "s", again: true)
        for _ in 0..<50 where store.wholeLoad(cut, in: "s") != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.text(cut, in: "s"), "First part and the rest")
        XCTAssertFalse(store.isCut(cut, in: "s"))
        XCTAssertEqual(store.wholeMessages("s").first?.text, "First part and the rest")
        // Another entry at that seq doesn't take it.
        let other = TranscriptMessage(seq: 3, uuid: "b", role: .assistant, text: "Else", textTruncated: true)
        XCTAssertEqual(store.text(other, in: "s"), "Else")
    }

    func testAutopilotAndAccountsWaitForTheirCapabilities() async throws {
        let live = MacTools()
        XCTAssertFalse(live.can(.accountsUse))
        XCTAssertFalse(live.can(.autopilotToggle))
        // No Mac to sign for: Use This Account says so rather than switching.
        let work = RemoteAccount(id: "w", name: "Work", provider: .claude, ready: true)
        do { try await live.useAccount(work); XCTFail() } catch ToolError.demo {}

        let demo = MacTools(demo: .init(options: OptionsList(agents: []), projects: []))
        XCTAssertTrue(demo.can(.accountsUse) && demo.can(.autopilotToggle))
        try await demo.setAutopilot(false)
        XCTAssertEqual(demo.autopilot?.enabled, false)
        XCTAssertFalse(live.can(.autopilotAnswers))
        XCTAssertTrue(demo.can(.autopilotAnswers))
        try await demo.setAnswersRecommended(true)
        XCTAssertEqual(demo.autopilot?.answersRecommended, true)
        XCTAssertEqual(demo.autopilot?.enabled, false)
        XCTAssertTrue(work.with(active: true).active)
        XCTAssertEqual(work.with(active: true).name, "Work")
    }

    func testThePlanFoldsToTheStepInProgress() {
        let plan = TurnPlan(steps: [TranscriptTodo(text: "a", status: .completed), TranscriptTodo(text: "b", status: .pending),
                                    TranscriptTodo(text: "c", status: .inProgress)])
        XCTAssertEqual(plan.done, 1)
        XCTAssertEqual(plan.current?.text, "c")
        XCTAssertEqual(TurnPlan(steps: [TranscriptTodo(text: "a", status: .completed), TranscriptTodo(text: "b", status: .pending)]).current?.text, "b")
        XCTAssertNil(TurnPlan(steps: [TranscriptTodo(text: "a", status: .completed)]).current)
    }

    func testAttentionLeadsWithTheMacsSentence() {
        let unsent = HostedAttention(name: "h", kind: .unsent, text: "It may not have been sent.")
        XCTAssertEqual(unsent.title, "It may not have been sent.")
        XCTAssertNil(unsent.detail)
        let screen = HostedAttention(name: "h", kind: .screen, text: "Esc to cancel\n\n❯ 1. Yes\n  2. No")
        XCTAssertEqual(screen.title, "Esc to cancel")
        XCTAssertEqual(screen.detail, "❯ 1. Yes\n2. No")
        let trust = HostedAttention(name: "h", kind: .trust, text: "Do you trust the files in this folder?")
        XCTAssertEqual(trust.title, "Waiting for you to trust this folder")
        XCTAssertEqual(trust.detail, "Do you trust the files in this folder?")
        XCTAssertEqual(HostedAttention(name: "h", kind: .unsent, text: "").title, "It may not have been sent.")
    }

    func testFailureCards() async {
        let declined = await PairingFailure(RemoteFailure(status: 403, error: APIError(code: .declined, message: "")), macName: "MacBook Pro")
        XCTAssertEqual(declined.title, "Pairing was cancelled on MacBook Pro.")
        XCTAssertEqual(declined.primary, .scanNewCode)

        let limited = await PairingFailure(RemoteFailure(status: 429, error: APIError(code: .rateLimited, message: "", retryable: true), retryAfter: 30),
                                           macName: "MacBook Pro")
        XCTAssertEqual(limited.retryAfter, 30)

        let refused = await PairingFailure(URLError(.cannotConnectToHost), macName: "MacBook Pro")
        XCTAssertEqual(refused.title, "Open Side A on MacBook Pro and try again.")

        let wrongKey = await PairingFailure(URLError(.cancelled), macName: "MacBook Pro")
        XCTAssertEqual(wrongKey.primary, .scanAgain)

        // TLS failing is not a different Mac: the code goes behind Details, never in the title.
        let tls = await PairingFailure(URLError(.secureConnectionFailed, userInfo: ["_kCFStreamErrorCodeKey": -9802]), macName: "MacBook Pro")
        XCTAssertEqual(tls.title, "Couldn't connect securely to MacBook Pro.")
        XCTAssertEqual(tls.detail, "TLS error -1200 (-9802)")

        // The Mac voids a code whose comparison ran out, so retrying it can't work.
        let spent = await PairingFailure(URLError(.timedOut), macName: "MacBook Pro", codeSpent: true)
        XCTAssertEqual(spent.primary, .scanNewCode)

        let badCode = await PairingFailure(RemoteFailure(status: 400, error: APIError(code: .badCode, message: "")), macName: "MacBook Pro")
        XCTAssertEqual(badCode.primary, .scanNewCode)
    }

    func testANamelessInvitationNamesItsAddress() {
        let run = PairingRun(invitation: PairingClient.Invitation(address: "100.101.12.4:47800", fp: "k", code: "ABCD2345"))
        XCTAssertEqual(run.macName, "100.101.12.4")
    }

    /// Real suggestions are a whole sentence; only the rule is code.
    func testAlwaysLineMonosOnlyTheRule() {
        let text = ApprovalSheet.ruleInMono("Always allow Bash(npm test:*) in this project")
        let mono = text.runs.filter { $0.font != nil }.map { String(text[$0.range].characters) }
        XCTAssertEqual(mono, ["Bash(npm test:*)"])
        XCTAssertEqual(String(text.characters), "Always allow Bash(npm test:*) in this project")
    }

    func testPlanApprovalSaysWhatItDid() {
        XCTAssertEqual(RequestOutcome.approvedPlan(acceptEdits: false).line, "Approved the plan")
        let request = DemoData(now: .now).requests[0]
        let store = RequestsStore([request])
        var outcome: RequestOutcome?
        store.onResolve = { outcome = $1 }
        store.answer(request.id, .approvePlan(acceptEdits: true))
        XCTAssertEqual(outcome, .approvedPlan(acceptEdits: true))
    }

    /// A request that leaves the Mac's list without an answer from here folds as "Answered on Mac".
    func testRequestGoneFromTheMacFoldsAsAnsweredOnMac() {
        let requests = DemoData(now: .now).requests
        let store = RequestsStore([])
        var outcomes: [RequestID: RequestOutcome] = [:]
        store.onResolve = { outcomes[$0.id] = $1 }
        store.replace(Dictionary(uniqueKeysWithValues: requests.prefix(2).map { ($0.id, $0) }))
        store.answer(requests[0].id, .deny(message: nil))
        store.replace([:]) { $0 == requests[1].id ? "Denied on Mac" : nil }
        XCTAssertEqual(outcomes, [requests[0].id: .denied, requests[1].id: .elsewhere("Denied on Mac")])
    }

    /// A Mac that restarts drops its open requests without settling them: they just go.
    func testRequestGoneWithoutAReasonLeavesNoLine() {
        let request = DemoData(now: .now).requests[0]
        let store = RequestsStore([request])
        var resolved = 0
        store.onResolve = { _, _ in resolved += 1 }
        store.replace([:])
        XCTAssertEqual(resolved, 0)
        XCTAssertTrue(store.open.isEmpty)
    }

    func testResolutionLines() {
        let mac = RequestResolution(requestID: "r", by: .mac, answer: .deny, at: 0)
        XCTAssertEqual(mac.line(thisDevice: "me"), "Denied on Mac")
        XCTAssertEqual(RequestResolution(requestID: "r", by: .device, deviceID: "me", at: 0).line(thisDevice: "me"), "Answered from a notification")
        XCTAssertEqual(RequestResolution(requestID: "r", by: .autoAnswered, answer: .answers, at: 0).line(thisDevice: "me"),
                       "Answered with recommended after a minute")
        XCTAssertEqual(RequestResolution(requestID: "r", by: .autoAnswered, answer: .approvePlan, at: 0).line(thisDevice: "me"),
                       "Plan approved after a minute")
        XCTAssertEqual(RequestResolution(requestID: "r", by: .device, deviceID: "ipad", deviceName: "iPad", at: 0).line(thisDevice: "me"),
                       "Answered on iPad")
    }
}
