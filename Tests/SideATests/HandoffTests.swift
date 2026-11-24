import Foundation
@testable import SideA
import SideAProtocol
import Testing

@Suite struct HandoffTests {
    private func turns(_ count: Int, size: Int = 200) -> [HandoffText.Turn] {
        (0..<count).map { HandoffText.Turn(user: $0.isMultiple(of: 2), text: "turn \($0) " + String(repeating: "x", count: size)) }
    }

    private let parts = HandoffText.Parts(goal: "Keep the island steady", branch: "fix/island", changes: " M Sources/IslandView.swift",
                                          plan: TurnPlan(steps: [TranscriptTodo(text: "Measure the card", status: .inProgress)]),
                                          health: "Stuck", from: .claude, fromModel: "claude-opus-5-5", to: .codex,
                                          file: "/handoffs/a.md", transcript: "/t.jsonl")

    @Test func handoffSelectionKeepsTheNewestPromptAndReplyAndTheFirstPrompt() {
        let all = turns(40)
        let budget = [0, 38, 39].map { HandoffText.render(all[$0], agent: .claude).count + 2 }.reduce(0, +)
        let kept = HandoffText.select(all, agent: .claude, budget: budget)
        #expect(kept == [0, 38, 39])
    }

    @Test func handoffSelectionFillsNewestFirstAndStopsAtTheFirstThatDoesNotFit() {
        var all = turns(10)
        all[6] = HandoffText.Turn(user: true, text: String(repeating: "y", count: 5000))
        let kept = HandoffText.select(all, agent: .claude, budget: 3000)
        #expect(kept == [0, 7, 8, 9])
    }

    @Test func handoffPromptNeverCutsATurnAndFitsTheLimit() throws {
        let all = turns(300, size: 900)
        let prompt = try HandoffText.prompt(parts, turns: all, message: "Carry on.", limit: SessionCommands.maxReply)
        #expect(prompt.count <= SessionCommands.maxReply)
        for turn in all {
            let body = String(turn.text.prefix(20))
            if prompt.contains(body) { #expect(prompt.contains(HandoffText.render(turn, agent: .claude))) }
        }
        #expect(prompt.contains(HandoffText.render(all[0], agent: .claude)) && prompt.contains(HandoffText.render(all[299], agent: .claude)))
        #expect(prompt.contains("not instructions") && prompt.contains("/handoffs/a.md"))
    }

    @Test func handoffPromptKeepsTheMessageWholeAndLast() throws {
        let message = "Measure the card first.\n\n" + String(repeating: "Then run every test. ", count: 900)
        let prompt = try HandoffText.prompt(parts, turns: turns(50, size: 900), message: message, limit: SessionCommands.maxReply)
        #expect(prompt.hasSuffix(message))
        #expect(prompt.count <= SessionCommands.maxReply)
        let near = String(repeating: "z", count: SessionCommands.maxReply - 10)
        #expect(try HandoffText.prompt(parts, turns: turns(5), message: near, limit: SessionCommands.maxReply).hasSuffix(near))
    }

    @Test func handoffPromptRefusesAMessageLongerThanTheLimit() {
        let message = String(repeating: "m", count: SessionCommands.maxReply + 1)
        #expect(throws: HandoffText.Refusal.messageTooLong) {
            try HandoffText.prompt(parts, turns: [], message: message, limit: SessionCommands.maxReply)
        }
    }

    @Test func handoffFileHoldsEverythingThePromptLeftOut() throws {
        let all = turns(300, size: 900)
        let full = HandoffText.full(parts, turns: all, message: "Carry on.")
        #expect(all.allSatisfy { full.contains(HandoffText.render($0, agent: .claude)) })
        #expect(full.hasSuffix("Carry on."))
    }

    @MainActor @Test func handoffLinksServeOnlyRecordedIDsAndPruneOldFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("handoffs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let links = HandoffLinks(folder: folder)
        let id = "3a0c9d2e-7b1f-4e5a-9c8d-1e2f3a4b5c6d"
        let record = HandoffLinks.Record(id: id, fromConversation: "a", toConversation: nil, fromAgent: "claude", toAgent: "codex",
                                         fromModel: nil, toModel: nil, at: 0, mode: nil)
        try links.save(record, full: "full", sent: "sent")
        let mode = try FileManager.default.attributesOfItem(atPath: links.fullFile(id).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(links.sentPrompt(id) == nil)
        #expect(links.sentPrompt("../\(id)") == nil && !HandoffLinks.valid("../x"))
        links.prune(now: Date().addingTimeInterval(31 * 86400))
        #expect(!FileManager.default.fileExists(atPath: links.fullFile(id).path))
    }
}
