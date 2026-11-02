import Foundation
@testable import SideACore
import SideAProtocol
import Testing

private typealias JSON = CodexAppServer.JSON

@Test func codexAppServerMessagesAreToldApartByIdAndMethod() throws {
    let parse = { (text: String) in CodexAppServer.parse(Data(text.utf8)) }
    #expect(parse(#"{"id":3,"result":{"data":["t"]}}"#) == .response(id: 3, result: .success(.object(["data": .array([.string("t")])]))))
    #expect(parse(#"{"id":4,"error":{"code":-32600,"message":"Invalid request: unknown variant `thread/queue/add`"}}"#)
            == .response(id: 4, result: .failure(.init(code: -32600, message: "Invalid request: unknown variant `thread/queue/add`"))))
    // The daemon's own requests can be numbered from 0, and are answered with that id as it came.
    #expect(parse(#"{"id":0,"method":"item/commandExecution/requestApproval","params":{"threadId":"t"}}"#)
            == .request(id: .number(0), method: "item/commandExecution/requestApproval", params: .object(["threadId": .string("t")])))
    #expect(parse(#"{"method":"turn/started","params":{}}"#) == .notification(method: "turn/started", params: .object([:])))
    #expect(parse("not json") == nil && parse(#"{"result":1}"#) == nil)
    // No "jsonrpc" field, and ids go back as integers.
    #expect(String(decoding: CodexAppServer.request(id: 7, method: "thread/read", params: .object(["threadId": .string("t")])), as: UTF8.self)
            == #"{"id":7,"method":"thread/read","params":{"threadId":"t"}}"#)
    #expect(String(decoding: CodexAppServer.response(id: .number(0), result: .object(["decision": .string("accept")])), as: UTF8.self)
            == #"{"id":0,"result":{"decision":"accept"}}"#)
}

@Test func anUnknownMethodIsEitherCodeTheDaemonUses() {
    #expect(CodexAppServer.RPCError(code: -32601, message: "Method not found").unknownMethod)
    #expect(CodexAppServer.RPCError(code: -32600, message: "Invalid request: unknown variant `thread/queue/add`, expected one of …").unknownMethod)
    #expect(!CodexAppServer.RPCError(code: -32600, message: "Invalid request: missing field `threadId`").unknownMethod)
    #expect(!CodexAppServer.RPCError(code: -32000, message: "thread not found").unknownMethod)
}

@Test func onlyTheUsersOwnThreadIsATerminalSession() throws {
    func thread(_ extra: [String: JSON]) -> CodexAppServer.Thread? {
        CodexAppServer.Thread(.object(["id": .string("t"), "cwd": .string("/r"), "path": .string("/h/rollout-t.jsonl"),
                                       "status": .object(["type": .string("active"), "activeFlags": .array([.string("waitingOnApproval")])])]
                                      .merging(extra) { $1 }))
    }
    let own = try #require(thread(["threadSource": .string("user"), "ephemeral": .bool(false)]))
    #expect(own.isUsers && own.status == .active(waitingOnApproval: true, waitingOnUserInput: false) && own.path == "/h/rollout-t.jsonl")
    // The title generator is ephemeral with source thread_title; a subagent has a parent.
    #expect(thread(["ephemeral": .bool(true), "threadSource": .string("thread_title")])?.isUsers == false)
    #expect(thread(["parentThreadId": .string("p")])?.isUsers == false)
    #expect(CodexAppServer.Thread.status(.object(["type": .string("idle")])) == .idle)
    #expect(CodexAppServer.Thread.status(nil) == .notLoaded)
}

@Test func approvalsShowTheModelsCommandAndAnswerInCodexsWords() throws {
    let params: JSON = .object(["threadId": .string("t"), "turnId": .string("u"), "itemId": .string("i"), "cwd": .string("/r"),
                                "command": .string("/bin/zsh -lc 'touch a'"), "reason": .string("Needs write access"),
                                "commandActions": .array([.object(["type": .string("unknown"), "command": .string("touch a")])])])
    let approval = try #require(CodexAppServer.Approval(id: .number(0), method: "item/commandExecution/requestApproval", params: params))
    let request = approval.request(files: [], diff: "")
    #expect(request.action == .command("touch a") && request.sessionID == "t" && request.agent == .codex && request.reason == "Needs write access")
    #expect(CodexAppServer.Approval(id: .number(1), method: "item/permissions/requestApproval", params: params) == nil)
    #expect(CodexAppServer.Approval.decision(.allow) == .object(["decision": .string("accept")]))
    #expect(CodexAppServer.Approval.decision(.deny(nil)) == .object(["decision": .string("decline")]))
    #expect(CodexAppServer.Approval.decision(.terminal) == nil)
    let item: JSON = .object(["type": .string("fileChange"), "changes": .array([.object(["path": .string("/r/a.swift"), "diff": .string("+x")])])])
    #expect(CodexAppServer.changes(item)?.files == ["/r/a.swift"])
}

@Test func clientFramesRoundTripThroughFragmentsAndLongLengths() throws {
    let mask: [UInt8] = [1, 2, 3, 4]
    var parser = CodexAppServer.Frames.Parser()
    let long = Data(repeating: 0x61, count: 70_000)
    let medium = Data(repeating: 0x62, count: 300)
    // A text frame split across a continuation, fed one byte at a time, then a 16-bit and a 64-bit length.
    var first = CodexAppServer.Frames.frame(.text, Data("{\"id\":".utf8), mask: mask); first[0] &= 0x7F
    var second = CodexAppServer.Frames.frame(.continuation, Data("1}".utf8), mask: mask); second[0] = 0x80
    var out: [(WebSocketCodec.Opcode, Data)] = []
    for byte in first + second { out += try parser.feed(Data([byte])) }
    out += try parser.feed(CodexAppServer.Frames.frame(.text, medium, mask: mask) + CodexAppServer.Frames.frame(.binary, long, mask: mask))
    #expect(out.map(\.0) == [.text, .text, .binary])
    #expect(out.map(\.1) == [Data("{\"id\":1}".utf8), medium, long])
    // The daemon's own frames are unmasked.
    #expect(try parser.feed(WebSocketCodec.frame(.text, Data("x".utf8))).map(\.1) == [Data("x".utf8)])
    let key = "dGhlIHNhbXBsZSBub25jZQ=="
    let ok = Data("HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\nrest".utf8)
    #expect(try CodexAppServer.Frames.accepted(ok, key: key) == Data("rest".utf8))
    #expect(try CodexAppServer.Frames.accepted(ok.prefix(20), key: key) == nil)
    #expect(throws: AppServerClient.Failure.refused) { try CodexAppServer.Frames.accepted(Data("HTTP/1.1 403 Forbidden\r\n\r\n".utf8), key: key) }
}

private func json(_ text: String) throws -> JSON { try JSONDecoder().decode(JSON.self, from: Data(text.utf8)) }

@Test func aThreadsSettingsComeFromResumeAndUpdatesAndAModeKeepsTheEffort() throws {
    // As Codex 0.163 sends them.
    let resumed = try json(#"{"model":"mock-model","reasoningEffort":null,"collaborationMode":{"mode":"default","settings":{"model":"mock-model","reasoning_effort":null,"developer_instructions":null}}}"#)
    #expect(CodexAppServer.Settings(resumed: resumed) == .init(model: "mock-model", effort: nil, mode: "default"))
    let updated = try json(##"{"model":"gpt-6.1-sol","effort":"high","collaborationMode":{"mode":"plan","settings":{"model":"gpt-6.1-sol","reasoning_effort":"high","developer_instructions":"# Plan Mode"}}}"##)
    let settings = try #require(CodexAppServer.Settings(updated: updated))
    #expect(settings == .init(model: "gpt-6.1-sol", effort: "high", mode: "plan"))

    #expect(settings.update(thread: "t", model: nil, effort: "low", mode: nil) == .object(["threadId": .string("t"), "effort": .string("low")]))
    // Back to default: the daemon would clear the effort without it.
    let mode = settings.update(thread: "t", model: nil, effort: nil, mode: "default")
    #expect(mode["collaborationMode"] == .object(["mode": .string("default"), "settings": .object([
        "model": .string("gpt-6.1-sol"), "reasoning_effort": .string("high"), "developer_instructions": .null])]))
    #expect(mode["model"] == nil && mode["effort"] == nil)
    let both = settings.update(thread: "t", model: "gpt-5.5", effort: "medium", mode: "plan")
    #expect(both["collaborationMode"]?["settings"]?["model"] == .string("gpt-5.5") && both["collaborationMode"]?["settings"]?["reasoning_effort"] == .string("medium"))
}

@Test func modelsListOnlyWhatThePickerShows() throws {
    let list = try json(#"[{"id":"gpt-6.1-sol","displayName":"GPT-6.1-Sol","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"},{"reasoningEffort":"high","description":"Deep"}],"defaultReasoningEffort":"low","isDefault":true},{"id":"codex-auto-review","displayName":"Review","hidden":true,"supportedReasoningEfforts":[],"defaultReasoningEffort":"low","isDefault":false}]"#)
    let models = list.array?.compactMap(CodexAppServer.Model.init) ?? []
    #expect(models.map(\.id) == ["gpt-6.1-sol"])
    #expect(models.first?.efforts == ["low", "high"] && models.first?.defaultEffort == "low" && models.first?.isDefault == true && models.first?.name == "GPT-6.1-Sol")
}

@Test func contextIsCountedAsTheTUIsFooterCountsIt() throws {
    let usage = { (used: Int, window: Int?) in
        let window = window.map(String.init) ?? "null"
        return try json(#"{"last":{"totalTokens":\#(used)},"total":{"totalTokens":\#(used * 3)},"modelContextWindow":\#(window)}"#)
    }
    // 12,300 of 258,400 is 0% past the baseline the footer leaves out.
    #expect(CodexAppServer.contextPercent(try usage(12_300, 258_400)) == 0)
    #expect(CodexAppServer.contextPercent(try usage(135_200, 258_400)) == 50)
    #expect(CodexAppServer.contextPercent(try usage(300_000, 258_400)) == 100)
    #expect(CodexAppServer.contextPercent(try usage(5_000, nil)) == nil)
}

@Test func limitsAndCostReadAsTheBridgeNamesThem() throws {
    let snapshot = try json(#"{"limitId":"codex","primary":{"usedPercent":42.5,"windowDurationMins":300,"resetsAt":1792400000},"secondary":{"usedPercent":101,"windowDurationMins":10080,"resetsAt":null},"credits":null}"#)
    #expect(CodexAppServer.windows(snapshot) == [UsageWindow(id: "five_hour", label: "5-hour", percent: 42.5, resetsAt: 1_792_400_000),
                                                 UsageWindow(id: "seven_day", label: "Weekly", percent: 100, resetsAt: nil)])
    // As 0.163 sends a rolling update with nothing in it, and another model's own limit.
    #expect(CodexAppServer.windows(try json(#"{"limitId":"codex","primary":null,"secondary":null}"#)).isEmpty)
    #expect(CodexAppServer.windows(try json(#"{"limitId":"codex_other","primary":{"usedPercent":5,"windowDurationMins":300}}"#)).isEmpty)
    #expect(CodexAppServer.cost(try json(#"{"summary":{},"threadUsage":{"threadId":"t","estimatedUsageCreditsMicros":9,"estimatedUsageUsdMicros":1250000,"groups":[]}}"#)) == 1.25)
    #expect(CodexAppServer.cost(try json(#"{"summary":{},"threadUsage":{"threadId":"t","estimatedUsageCreditsMicros":9,"estimatedUsageUsdMicros":null,"groups":[]}}"#)) == nil)
}

@Test func raisesShowAsOneModeAndLowerBackToWhatTheSessionHad() throws {
    let resumed = try json(#"{"model":"m","reasoningEffort":"high","collaborationMode":{"mode":"default"},"approvalPolicy":"on-request","sandbox":{"type":"readOnly","networkAccess":false}}"#)
    let base = try #require(CodexAppServer.Settings(resumed: resumed))
    #expect(!base.raised && base.shown == "default")
    #expect(base.raise(thread: "t", to: "never") == .object(["threadId": .string("t"), "approvalPolicy": .string("never")]))
    #expect(base.raise(thread: "t", to: "dangerFullAccess") == .object(["threadId": .string("t"), "sandboxPolicy": .object(["type": .string("dangerFullAccess")])]))
    var raised = base
    raised.approval = .string("never")
    #expect(raised.shown == "never")
    raised.sandbox = .object(["type": .string("dangerFullAccess")])
    #expect(raised.shown == "dangerFullAccess")
    raised.mode = "plan"
    #expect(raised.shown == "plan" && raised.raised)
    #expect(CodexAppServer.Settings.lower(thread: "t", to: base) == .object(["threadId": .string("t"), "approvalPolicy": .string("on-request"),
                                                                          "sandboxPolicy": .object(["type": .string("readOnly"), "networkAccess": .bool(false)])]))
}

@Test func aTurnsDiffSplitsIntoFilesAsGitWritesIt() throws {
    // As Codex 0.163 sent it for an added file.
    let added = "diff --git a/l10-diff.txt b/l10-diff.txt\nnew file mode 100644\nindex 0000000000000000000000000000000000000000..06fcdd77c9348567c50638b30d406500f521c304\n--- /dev/null\n+++ b/l10-diff.txt\n@@ -0,0 +1,2 @@\n+first line\n+second line\n"
    #expect(CodexAppServer.fileDiffs(added) == [FileDiff(path: "l10-diff.txt", change: .added, additions: 2, deletions: 0,
                                                         hunks: [DiffHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: 2, lines: ["+first line", "+second line"])])])
    let several = """
    diff --git a/src/a.swift b/src/a.swift
    index 1111111..2222222 100644
    --- a/src/a.swift
    +++ b/src/a.swift
    @@ -1,3 +1,3 @@
     keep
    -old
    +new
    @@ -10 +10,2 @@
     ten
    +eleven
    \\ No newline at end of file
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    index 3333333..0000000
    --- a/gone.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -bye
    diff --git a/old name.txt b/new name.txt
    similarity index 100%
    rename from old name.txt
    rename to new name.txt

    """
    let files = CodexAppServer.fileDiffs(several)
    #expect(files.map(\.path) == ["src/a.swift", "gone.txt", "new name.txt"])
    #expect(files.map(\.change) == [.modified, .deleted, .renamed])
    #expect(files[0].hunks.count == 2 && files[0].hunks[1] == DiffHunk(oldStart: 10, oldCount: 1, newStart: 10, newCount: 2,
                                                                         lines: [" ten", "+eleven", "\\ No newline at end of file"]))
    #expect((files[0].additions, files[0].deletions, files[1].deletions) == (2, 1, 1))
    #expect(files[2].oldPath == "old name.txt" && files[2].hunks.isEmpty)
    // Past the cap: counted in full, kept in part.
    let long = "diff --git a/big b/big\n--- a/big\n+++ b/big\n@@ -0,0 +1,2001 @@\n" + (1...2_001).map { "+\($0)" }.joined(separator: "\n")
    let big = try #require(CodexAppServer.fileDiffs(long).first)
    #expect(big.additions == 2_001 && big.truncated && big.hunks.first?.lines.count == 2_000)
}

@Test func aTurnsPlanIsItsSteps() throws {
    let params = try json(#"{"threadId":"t","turnId":"u","explanation":"Two steps.","plan":[{"step":"Read the code","status":"completed"},{"step":"Write the fix","status":"inProgress"}]}"#)
    #expect(CodexAppServer.plan(params) == TurnPlan(explanation: "Two steps.", steps: [TranscriptTodo(text: "Read the code", status: .completed),
                                                                                      TranscriptTodo(text: "Write the fix", status: .inProgress)]))
}
