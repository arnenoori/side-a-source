import Foundation

/// What Claude Code's transcript says it did with a message typed into its composer. Checked against Claude Code 2.1
/// transcripts: Enter mid-turn writes `queue-operation` `enqueue` with the text; reading it at the next step writes
/// `remove` with reason `absorbed_mid_turn` or `delivered_to_agent`, the first usually followed by a `queued_command`
/// attachment with the same text; taken as the next prompt it is a `dequeue` (no text) and a `user` line. A `remove`
/// with no reason let it go unread. Each line is about one message, so a caller gives each to one reply only.
public enum ClaudeQueueEvidence {
    public enum Event: Equatable, Sendable {
        case held(text: String, at: Double)
        case read(text: String, at: Double, from: Source)
        case letGo(text: String, at: Double)
    }

    /// The `queued_command` attachment after a `remove` is the same message again, not a second one.
    public enum Source: Equatable, Sendable { case removed, attachment, prompt }

    /// The only reasons seen in real transcripts; an unknown one must not claim read.
    public static let readReasons: Set<String> = ["absorbed_mid_turn", "delivered_to_agent"]

    public static func event(_ line: Substring) -> Event? {
        guard line.contains("\"queue-operation\"") || line.contains("\"queued_command\"") || line.contains("\"type\":\"user\""),
              let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        var at: Double { ReplyText.at(entry) }
        switch entry["type"] as? String {
        case "queue-operation":
            guard let text = text(entry["content"]) else { return nil }
            switch (entry["operation"] as? String, entry["reason"] as? String) {
            case ("enqueue", _): return .held(text: text, at: at)
            case ("remove", nil): return .letGo(text: text, at: at)
            // Only `absorbed_mid_turn` was seen followed by a `queued_command` echo.
            case ("remove", let reason?) where readReasons.contains(reason): return .read(text: text, at: at, from: reason == "absorbed_mid_turn" ? .removed : .prompt)
            default: return nil
            }
        case "attachment":
            let attachment = entry["attachment"] as? [String: Any]
            guard attachment?["type"] as? String == "queued_command", let text = text(attachment?["prompt"]) else { return nil }
            return .read(text: text, at: at, from: .attachment)
        case "user":
            guard entry["isMeta"] as? Bool != true, let text = text((entry["message"] as? [String: Any])?["content"]) else { return nil }
            return .read(text: text, at: at, from: .prompt)
        default: return nil
        }
    }

    /// By the bridge's `prompt_uuid` rule, so the uuid is the session's `turnID`.
    public static func turn(_ line: Substring) -> (id: String, text: String, at: Double)? {
        guard line.contains("\"queued_command\"") || line.contains("\"type\":\"user\""),
              let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              entry["isSidechain"] as? Bool != true, let id = entry["uuid"] as? String else { return nil }
        let content: Any?
        switch entry["type"] as? String {
        case "attachment":
            let attachment = entry["attachment"] as? [String: Any]
            guard attachment?["type"] as? String == "queued_command",
                  [nil, "prompt", "task-notification"].contains(attachment?["commandMode"] as? String) else { return nil }
            content = attachment?["prompt"]
        case "user":
            guard entry["isMeta"] as? Bool != true, entry["isCompactSummary"] as? Bool != true else { return nil }
            content = (entry["message"] as? [String: Any])?["content"]
        default: return nil
        }
        let words = (text(content) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pasted = (content as? [[String: Any]])?.contains { $0["type"] as? String == "image" } == true
        let injected = ["<local-command", "<system-reminder>", "Caveat:", "<bash-", "[Request interrupted"].contains { words.hasPrefix($0) }
        guard !injected, !words.isEmpty || pasted else { return nil }
        return (id, words, ReplyText.at(entry))
    }

    /// Whole words only: Claude Code writes a queued message uncut (3,000 transcripts, up to 142,393 characters), and two
    /// that only start alike, as its cross-session messages all do, are two messages.
    public enum Match: Equatable, Sendable { case exact }

    public static func match(_ theirs: String, _ sent: String) -> Match? {
        let mine = ReplyText.key(sent)
        return !mine.isEmpty && ReplyText.key(theirs) == mine ? .exact : nil
    }

    private static func text(_ content: Any?) -> String? { ReplyText.words(content, blocks: ["text"]) }
}
