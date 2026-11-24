import Foundation
@testable import SideACore
import Testing

// Transcript lines in the shape Claude Code 2.1 and Codex 0.169 write them, cut to the fields the readers use.
private let stamp = "\"timestamp\":\"2026-11-01T10:00:00.500Z\""
private let at = 1_793_527_200.5

private func claude(_ json: String) -> ClaudeQueueEvidence.Event? { ClaudeQueueEvidence.event(Substring(json)) }
private func codex(_ json: String) -> CodexInputEvidence.Event? { CodexInputEvidence.event(Substring(json)) }

@Test func claudesQueueLinesSayHeldReadOrLetGo() {
    #expect(claude(#"{"type":"queue-operation","operation":"enqueue",\#(stamp),"content":"fix it"}"#) == .held(text: "fix it", at: at))
    #expect(claude(#"{"type":"queue-operation","operation":"remove",\#(stamp),"content":"fix it"}"#) == .letGo(text: "fix it", at: at))
    #expect(claude(#"{"type":"queue-operation","operation":"remove","reason":"absorbed_mid_turn",\#(stamp),"content":"fix it"}"#)
        == .read(text: "fix it", at: at, from: .removed))
    #expect(claude(#"{"type":"queue-operation","operation":"remove","reason":"delivered_to_agent",\#(stamp),"content":"fix it"}"#)
        == .read(text: "fix it", at: at, from: .prompt))
    #expect(claude(#"{"type":"queue-operation","operation":"remove","reason":"cancelled_by_user",\#(stamp),"content":"fix it"}"#) == nil)
    #expect(claude(#"{"type":"queue-operation","operation":"dequeue",\#(stamp)}"#) == nil)
    #expect(claude(#"{"type":"attachment","attachment":{"type":"queued_command","prompt":"fix it"},\#(stamp)}"#)
        == .read(text: "fix it", at: at, from: .attachment))
    #expect(claude(#"{"type":"attachment","attachment":{"type":"file","prompt":"fix it"},\#(stamp),"x":"queued_command"}"#) == nil)
    #expect(claude(#"{"type":"user","isMeta":true,"message":{"content":"Caveat: local"},\#(stamp)}"#) == nil)
    #expect(claude(#"{"type":"user","message":{"content":[{"type":"text","text":"a"},{"type":"image"},{"type":"text","text":"b"}]},\#(stamp)}"#)
        == .read(text: "a\nb", at: at, from: .prompt))
    #expect(claude(#"{"type":"assistant","message":{"content":"fix it"}}"#) == nil)
    #expect(claude("not json \"queue-operation\"") == nil)
}

@Test func aQueuedMessageMatchesOnlyTheSameWholeWords() {
    #expect(ClaudeQueueEvidence.match("fix  it\n", "fix it") == .exact)
    #expect(ClaudeQueueEvidence.match("[Image #1] fix it", "fix it") == .exact)
    #expect(ClaudeQueueEvidence.match("fix it please", "fix it") == nil)
    #expect(ClaudeQueueEvidence.match("", "  ") == nil)
    #expect(CodexInputEvidence.match("fix\tit", "fix it") == .exact)
    #expect(CodexInputEvidence.match("fix it", "fix it now") == nil)
}

@Test func codexsRolloutLinesSayReadStartedOrEnded() {
    #expect(codex(#"{"type":"response_item",\#(stamp),"payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}"#)
        == .read(text: "hello", at: at))
    #expect(codex(#"{"type":"response_item",\#(stamp),"payload":{"type":"message","role":"user","content":"hi"}}"#) == .read(text: "hi", at: at))
    #expect(codex(#"{"type":"response_item",\#(stamp),"payload":{"type":"message","role":"assistant","content":"user"}}"#) == nil)
    #expect(codex(#"{"type":"event_msg",\#(stamp),"payload":{"type":"task_started","turn_id":"t1"}}"#) == .started)
    #expect(codex(#"{"type":"event_msg",\#(stamp),"payload":{"type":"task_complete"}}"#) == .ended(at: at, interrupted: false))
    #expect(codex(#"{"type":"event_msg",\#(stamp),"payload":{"type":"turn_aborted"}}"#) == .ended(at: at, interrupted: true))
    #expect(codex(#"{"type":"event_msg",\#(stamp),"payload":{"type":"agent_message","text":"user"}}"#) == nil)
    let started = CodexInputEvidence.started(#"{"type":"event_msg",\#(stamp),"payload":{"type":"task_started","turn_id":"t1"}}"#)
    #expect(started?.id == "t1" && started?.at == at)
    #expect(CodexInputEvidence.prompt(#"{"type":"response_item",\#(stamp),"payload":{"type":"message","role":"user","content":"  hi \n"}}"#) == "hi")
    #expect(CodexInputEvidence.prompt(#"{"type":"response_item",\#(stamp),"payload":{"type":"message","role":"user","content":"<environment_context>x"}}"#) == nil)
}
