import SideAProtocol
import SideARemoteShared
import XCTest
@testable import SideARemote

@MainActor
final class TranscriptLayoutTests: XCTestCase {
    private func tool(_ id: String, at: Timestamp, status: TranscriptTool.Status = .ok) -> TranscriptTool {
        TranscriptTool(id: id, name: "Read", summary: id, action: .read(path: "/x/\(id).swift"), status: status,
                       startedAt: at, endedAt: status == .running ? nil : at + 1)
    }

    func testShortRunsStayFlat() {
        let messages = [
            TranscriptMessage(seq: 0, uuid: "u", role: .user, at: 0, text: "Go"),
            TranscriptMessage(seq: 1, uuid: "t", role: .tools, at: 1, tools: (1...3).map { tool("t\($0)", at: Double($0)) }),
            TranscriptMessage(seq: 2, uuid: "a", role: .assistant, at: 10, model: "opus", text: "Done"),
        ]
        let items = TranscriptLayout.items(messages: messages, earlier: 0)
        XCTAssertEqual(items.filter { if case .tool = $0 { true } else { false } }.count, 3)
        XCTAssertFalse(items.contains { if case .group = $0 { true } else { false } })
    }

    func testLongRunsFoldIntoAStepGroupWithElapsedTime() throws {
        let messages = [
            TranscriptMessage(seq: 0, uuid: "u", role: .user, at: 0, text: "Go"),
            TranscriptMessage(seq: 1, uuid: "t", role: .tools, at: 0, tools: (0..<14).map { tool("t\($0)", at: Double($0) * 5) }),
            TranscriptMessage(seq: 2, uuid: "a", role: .assistant, at: 80, text: "Done"),
        ]
        let items = TranscriptLayout.items(messages: messages, earlier: 0)
        let group = try XCTUnwrap(items.lazy.compactMap { if case .group(let g) = $0 { g } else { nil } }.first)
        XCTAssertEqual(group.tools.count, 14)
        XCTAssertEqual(group.title, "Worked for 1m 6s · 14 steps")
        XCTAssertFalse(TranscriptLayout.startsExpanded(group))
    }

    func testRunningGroupStartsOpen() throws {
        let tools = (0..<5).map { tool("t\($0)", at: Double($0), status: $0 == 4 ? .running : .ok) }
        let items = TranscriptLayout.items(messages: [TranscriptMessage(seq: 0, uuid: "t", role: .tools, at: 0, tools: tools)], earlier: 0, working: true)
        let group = try XCTUnwrap(items.lazy.compactMap { if case .group(let g) = $0 { g } else { nil } }.first)
        XCTAssertTrue(TranscriptLayout.startsExpanded(group))
    }

    func testDiffsSplitTheRunAndStandAlone() {
        let diff = FileDiff(path: "/x/a.swift", change: .modified, additions: 1, deletions: 1,
                            hunks: [DiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, lines: ["-a", "+b"])])
        let edit = TranscriptTool(id: "e", name: "Edit", summary: "a.swift", action: .edit(path: "/x/a.swift", removed: "a", added: "b"),
                                  status: .ok, diffs: [diff])
        let items = TranscriptLayout.items(messages: [TranscriptMessage(seq: 0, uuid: "t", role: .tools, at: 0, tools: [tool("r", at: 0), edit])], earlier: 0)
        XCTAssertEqual(items.map(\.id), ["t-r", "d-e-/x/a.swift"])
    }

    func testWrittenDocumentsBecomeFileChips() {
        let write = TranscriptTool(id: "w", name: "Write", summary: "plan.md", action: .write(path: "/x/plan.md", content: "abc"), status: .ok)
        let items = TranscriptLayout.items(messages: [TranscriptMessage(seq: 0, uuid: "t", role: .tools, at: 0, tools: [write])], earlier: 0)
        guard case .file(_, let path, let bytes) = items.first else { return XCTFail("expected a file chip") }
        XCTAssertEqual(path, "/x/plan.md")
        XCTAssertEqual(bytes, 3)
    }

    func testDateSeparatorOnlyAfterALongGap() {
        let messages = [
            TranscriptMessage(seq: 0, uuid: "u1", role: .user, at: 0, text: "a"),
            TranscriptMessage(seq: 1, uuid: "a1", role: .assistant, at: 10, text: "b"),
            TranscriptMessage(seq: 2, uuid: "u2", role: .user, at: 20 * 60, text: "c"),
            TranscriptMessage(seq: 3, uuid: "a2", role: .assistant, at: 21 * 60, text: "d"),
            TranscriptMessage(seq: 4, uuid: "u3", role: .user, at: 3 * 3600, text: "e"),
        ]
        let items = TranscriptLayout.items(messages: messages, earlier: 0)
        XCTAssertEqual(items.filter { if case .separator = $0 { true } else { false } }.count, 1)
    }

    func testTurnEndCarriesModelAndDuration() throws {
        let messages = [
            TranscriptMessage(seq: 0, uuid: "u", role: .user, at: 100, text: "a"),
            TranscriptMessage(seq: 1, uuid: "a", role: .assistant, at: 234, model: "opus", text: "b"),
        ]
        let items = TranscriptLayout.items(messages: messages, earlier: 0)
        guard case .turnEnd(let end) = try XCTUnwrap(items.last) else { return XCTFail("expected a turn end") }
        XCTAssertEqual(end.model, "opus")
        XCTAssertEqual(end.duration, 134)
        XCTAssertTrue(TranscriptLayout.items(messages: messages, earlier: 0, working: true).allSatisfy {
            if case .turnEnd = $0 { false } else { true }
        })
    }

    func testThinkingMessageBecomesAStepTimedByTheNextMessage() throws {
        let messages = [
            TranscriptMessage(seq: 0, uuid: "k", role: .thinking, at: 10, text: "Hmm"),
            TranscriptMessage(seq: 1, uuid: "a", role: .assistant, at: 14, text: "Done"),
        ]
        let items = TranscriptLayout.items(messages: messages, earlier: 0)
        guard case .thinking(let thought) = try XCTUnwrap(items.first) else { return XCTFail("expected thinking") }
        XCTAssertEqual(thought.duration, 4)
        XCTAssertEqual(thought.output, "Hmm")

        let live = TranscriptLayout.items(messages: [messages[0]], earlier: 0, working: true)
        guard case .thinking(let running) = try XCTUnwrap(live.first) else { return XCTFail("expected thinking") }
        XCTAssertEqual(running.status, .running)
    }

    func testOpenRequestsComeLastAndQuestionsGetTheirCard() {
        let question = RemoteRequest(id: "q", agent: .claude, tool: "AskUserQuestion",
                                     action: .question([IslandQuestion(question: "Where?", header: nil, options: [], multiSelect: false)]),
                                     risk: .low, answers: [.answers], title: "t", arrivedAt: 0)
        let bash = RemoteRequest(id: "b", agent: .claude, tool: "Bash", action: .command("ls"), risk: .normal, answers: [.allow, .deny], title: "t", arrivedAt: 0)
        let items = TranscriptLayout.items(messages: [TranscriptMessage(seq: 0, uuid: "u", role: .user, at: 0, text: "a")], earlier: 5, open: [bash, question])
        XCTAssertEqual(items.map(\.id), ["earlier", "m-0", "r-b", "r-q"])
        guard case .question = items.last else { return XCTFail("expected a question card") }
    }
}

@MainActor
final class ModelTests: XCTestCase {
    func testPhaseOrderPutsWhatNeedsYouFirst() {
        func session(_ status: SessionStatus, requests: [RequestID] = []) -> RemoteSession {
            RemoteSession(id: UUID().uuidString, agent: .claude, title: "t", project: "p", status: status, openRequests: requests)
        }
        XCTAssertEqual(SessionPhase(session(.working, requests: ["r"])), .needsYou)
        XCTAssertEqual(SessionPhase(session(.waiting)), .needsYou)
        XCTAssertEqual(SessionPhase(session(.starting)), .working)
        XCTAssertEqual(SessionPhase(session(.finished)), .ready)
        XCTAssertEqual(SessionPhase(session(.exited)), .idle)
        XCTAssertEqual(SessionPhase(session(SessionStatus(rawValue: "somethingNew"))), .idle)
    }

    func testAnsweringMovesTheRowOutOfNeedsYouAndFoldsTheCard() {
        let model = AppModel.demo()
        let id = DemoData.ID.syncRequest
        XCTAssertEqual(model.sessions.rows(.needsYou).count, 2)
        model.requests.answer(id, .allow(confirmDestructive: false))
        XCTAssertNil(model.requests.request(id))
        XCTAssertEqual(model.sessions.rows(.needsYou).count, 1)
        XCTAssertEqual(model.transcripts.answered[DemoData.ID.syncTest]?.first?.outcome, .allowed)
    }

    func testQuestionAnswerSummaryDropsRecommended() {
        let model = AppModel.demo()
        model.requests.answer(DemoData.ID.cacheQuestion, .answers([
            QuestionAnswer(question: "Where should the transcript cache live?", picked: ["Caches directory (Recommended)"]),
        ]))
        XCTAssertEqual(model.transcripts.answered[DemoData.ID.cache]?.first?.outcome, .answered("Caches directory"))
    }

    func testGroupingKeepsFirstAppearanceOrder() {
        let model = AppModel.demo()
        model.sessions.groupBy = .project
        XCTAssertEqual(model.sessions.groups(.working).map(\.title), ["side-a", "storefront"])
        model.sessions.groupBy = .none
        XCTAssertEqual(model.sessions.groups(.working).count, 1)
    }
}

@MainActor
final class FormattingTests: XCTestCase {
    func testElapsed() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(Formatting.elapsed(since: now.addingTimeInterval(-10), now: now), "now")
        XCTAssertEqual(Formatting.elapsed(since: now.addingTimeInterval(-120), now: now), "2m")
        XCTAssertEqual(Formatting.elapsed(since: now.addingTimeInterval(-3900), now: now), "1h 5m")
        XCTAssertEqual(Formatting.elapsed(since: now.addingTimeInterval(-3 * 86_400), now: now), "3d")
    }

    func testDuration() {
        XCTAssertNil(Formatting.duration(0.4))
        XCTAssertEqual(Formatting.duration(0.4, exact: true), "0.4s")
        XCTAssertEqual(Formatting.duration(41), "41s")
        XCTAssertEqual(Formatting.duration(72), "1m 12s")
        XCTAssertEqual(Formatting.duration(120), "2m")
    }

    func testMemoryOnlyFromOneGigabyte() {
        XCTAssertNil(Formatting.memory(900_000_000))
        XCTAssertEqual(Formatting.memory(1_400_000_000), "1.4 GB")
    }

    func testAgeIsQuietWhileFresh() {
        let now = Date()
        XCTAssertNil(Formatting.age(of: now.addingTimeInterval(-30), now: now))
        XCTAssertEqual(Formatting.age(of: now.addingTimeInterval(-240), now: now), "Updated 4 min ago")
    }
}

@MainActor
final class MarkdownTests: XCTestCase {
    func testBlocks() {
        let blocks = MarkdownParser.blocks("""
        Intro with `code`.

        ### Heading

        1. One
        2. Two

        - Dot

        > Quote

        ```swift
        let x = 1
        ```

        | A | B |
        |---|---|
        | 1 | 2 |
        """)
        let kinds = blocks.map(\.kind)
        XCTAssertEqual(kinds.first, .paragraph)
        XCTAssertTrue(kinds.contains(.heading(3)))
        XCTAssertTrue(kinds.contains(.listItem(marker: "1.", depth: 1)))
        XCTAssertTrue(kinds.contains(.listItem(marker: "2.", depth: 1)))
        XCTAssertTrue(kinds.contains(.listItem(marker: "•", depth: 1)))
        XCTAssertTrue(kinds.contains(.quote))
        XCTAssertTrue(kinds.contains(.code(language: "swift")))
        guard case .table(let header, let rows) = kinds.last else { return XCTFail("expected a table, got \(kinds)") }
        XCTAssertEqual(header.map { String($0.characters) }, ["A", "B"])
        XCTAssertEqual(rows.map { $0.map { String($0.characters) } }, [["1", "2"]])
    }

    func testListItemsWithSeveralInlineRunsStayOneBlock() {
        let blocks = MarkdownParser.blocks("1. Send `hello` first, then **wait**.")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(String(blocks[0].text.characters), "Send hello first, then wait.")
    }
}

@MainActor
final class ThinkingTests: XCTestCase {
    func testBackToBackThoughtsMergeWithTheirTimeSummed() throws {
        let messages = [
            TranscriptMessage(seq: 0, uuid: "k1", role: .thinking, at: 0, text: "", durationMS: 3000),
            TranscriptMessage(seq: 1, uuid: "k2", role: .thinking, at: 3, text: "", durationMS: 1000),
            TranscriptMessage(seq: 2, uuid: "a", role: .assistant, at: 5, text: "Done"),
        ]
        let items = TranscriptLayout.items(messages: messages, earlier: 0)
        XCTAssertEqual(items.filter { if case .thinking = $0 { true } else { false } }.count, 1)
        guard case .thinking(let thought) = try XCTUnwrap(items.first) else { return XCTFail("expected thinking") }
        XCTAssertEqual(thought.duration, 4)
        XCTAssertEqual(thought.output, "")
    }

    func testDurationComesFromTheWireWhenPresent() throws {
        let items = TranscriptLayout.items(messages: [TranscriptMessage(seq: 0, uuid: "k", role: .thinking, at: 0, text: "x", durationMS: 2500)],
                                           earlier: 0, working: true)
        guard case .thinking(let thought) = try XCTUnwrap(items.first) else { return XCTFail("expected thinking") }
        XCTAssertEqual(thought.status, .ok)
        XCTAssertEqual(thought.duration, 2.5)
    }
}

@MainActor
final class DeepLinkTests: XCTestCase {
    func testLinks() {
        XCTAssertEqual(DeepLink(URL(string: "sidea-remote://session/mac1/abc")!), .session("abc", mac: "mac1"))
        XCTAssertEqual(DeepLink(URL(string: "sidea-remote://request/mac1/r-1")!), .request("r-1", mac: "mac1"))
        XCTAssertEqual(DeepLink(URL(string: "sidea-remote://accounts")!), .accounts)
        XCTAssertNil(DeepLink(URL(string: "sidea-remote://session/abc")!))
        XCTAssertNil(DeepLink(URL(string: "https://session/mac/abc")!))
        XCTAssertEqual(DeepLink(URL(string: "sidea-remote://mac/mac1")!), .mac("mac1"))
        XCTAssertNil(DeepLink(URL(string: "sidea-remote://mac")!))
    }

    /// Open on a grouped Ready, which names no session, goes to that Mac's sessions; one turn's goes to its session.
    func testOpenOnReadyGoesToTheMacOrTheSession() {
        let grouped = PushPayload(t: PushKind.finished.rawValue, mac: "mac1", sent: 0, title: "3 sessions ready", body: "a, b, c")
        XCTAssertEqual(AppDelegate.link(for: grouped).flatMap(DeepLink.init), .mac("mac1"))
        let one = PushPayload(t: PushKind.finished.rawValue, mac: "mac1", sent: 0, sid: "s1", title: "a", turnID: "t1", summary: "Done.")
        XCTAssertEqual(AppDelegate.link(for: one).flatMap(DeepLink.init), .session("s1", mac: "mac1"))
        XCTAssertNil(AppDelegate.link(for: PushPayload(t: PushKind.limit.rawValue, mac: "mac1", sent: 0)))
    }
}
