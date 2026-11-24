import Foundation

extension IslandSuggestion {
    /// Where the rule would be kept, as Claude Code names it: "session", "localSettings", "projectSettings" or
    /// "userSettings". Codex's own keep-for-the-session counts as "session"; a mode switch keeps no rule and has none.
    public var destination: String? {
        guard let rule = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        switch rule["type"] as? String {
        case "codexSession": return "session"
        case "setMode": return nil
        default: return rule["destination"] as? String
        }
    }

    /// The same allow rule kept only until the session ends. Claude Code offers a rule for the project's settings;
    /// this is the narrower one a phone can grant without writing to a settings file.
    var forSession: IslandSuggestion? {
        guard var rule = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any], rule["type"] as? String == "addRules",
              rule["behavior"] as? String == "allow", rule["destination"] as? String != "session" else { return nil }
        rule["destination"] = "session"
        return IslandRequest.suggestion(rule)
    }
}

extension IslandRequest {
    /// What a phone may pick from: the agent's own suggestions first, so the first stays the one older phones show,
    /// then each allow rule narrowed to the session where the agent didn't offer that itself.
    public var remoteSuggestions: [IslandSuggestion] {
        var offered = suggestions
        for narrowed in suggestions.compactMap(\.forSession) where !offered.contains(where: { $0.json == narrowed.json }) {
            offered.append(narrowed)
        }
        return offered
    }
}
