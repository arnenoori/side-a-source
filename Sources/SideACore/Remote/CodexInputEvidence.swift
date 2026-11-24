import Foundation

/// What Codex 0.169 records of a message it was given. Its rollout keeps no queue: a steer (Enter mid-turn) or Tab's
/// queue writes nothing until a turn takes the message, as a `response_item` `message` with role `user`. The app server
/// says more, by `clientUserMessageId`: `turn/steer` answers once the running turn holds it, and a `userMessage` item
/// with that `clientId` is it taken.
public enum CodexInputEvidence {
    public enum Event: Equatable, Sendable {
        case read(text: String, at: Double)
        case ended(at: Double, interrupted: Bool)
        case started
    }

    public static func event(_ line: Substring) -> Event? {
        guard line.contains("\"user\"") || line.contains("\"task_") || line.contains("\"turn_aborted\""),
              let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let payload = entry["payload"] as? [String: Any] else { return nil }
        var at: Double { ReplyText.at(entry) }
        switch (entry["type"] as? String, payload["type"] as? String) {
        case ("response_item", "message"):
            guard payload["role"] as? String == "user", let text = text(payload["content"]) else { return nil }
            return .read(text: text, at: at)
        case ("event_msg", "task_started"): return .started
        case ("event_msg", "task_complete"): return .ended(at: at, interrupted: false)
        case ("event_msg", "turn_aborted"): return .ended(at: at, interrupted: true)
        default: return nil
        }
    }

    /// The bridge's `CODEX_NOISE`: Codex records these as user messages, but nobody typed them.
    static let injected = ["# AGENTS.md", "<environment_context>", "<user_instructions>", "<permissions", "<turn_aborted>", "## Memory"]

    public static func started(_ line: Substring) -> (id: String, at: Double)? {
        guard line.contains("\"task_started\""), let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let payload = entry["payload"] as? [String: Any], payload["type"] as? String == "task_started",
              let id = payload["turn_id"] as? String ?? entry["timestamp"] as? String else { return nil }
        return (id, ReplyText.at(entry))
    }

    public static func prompt(_ line: Substring) -> String? {
        guard case .read(let text, _)? = event(line) else { return nil }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return injected.contains { words.hasPrefix($0) } ? nil : words
    }

    /// The same words only: Codex records the input it was given whole, and two messages that only start alike are two.
    public static func match(_ theirs: String, _ sent: String) -> ClaudeQueueEvidence.Match? {
        ClaudeQueueEvidence.match(theirs, sent)
    }

    /// A `userMessage` item on the app server is `sent`, for a queued one whose `clientId` didn't survive the queue.
    public static func matches(_ item: CodexAppServer.JSON, _ sent: String) -> Bool {
        guard let text = item["content"]?.array?.compactMap({ $0["type"]?.string == "text" ? $0["text"]?.string : nil }).joined(separator: "\n") else { return false }
        return match(text, sent) != nil
    }

    /// The thread's rollout, `sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`, newest day first: a resumed thread keeps
    /// writing to the file of the day it started.
    public static func rollout(sessions: URL, id: String) -> URL? {
        let files = FileManager.default, name = "-\(id).jsonl"
        func newest(_ url: URL) -> [URL] {
            ((try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        for year in newest(sessions) {
            for month in newest(year) {
                for day in newest(month) {
                    if let hit = ((try? files.contentsOfDirectory(at: day, includingPropertiesForKeys: nil)) ?? []).first(where: {
                        $0.lastPathComponent.hasPrefix("rollout-") && $0.lastPathComponent.hasSuffix(name)
                    }) { return hit }
                }
            }
        }
        return nil
    }

    /// Typed input is `input_text` in a rollout.
    private static func text(_ content: Any?) -> String? { ReplyText.words(content, blocks: ["input_text", "text"]) }
}
