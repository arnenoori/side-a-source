import Foundation

/// The agent and API failures that matter to someone away from the Mac, from the words Claude Code, Codex, git and `gh`
/// print. Unlike `BridgeErrorKind` these come from a session's transcript, which only has words; a failure that matches
/// nothing here is left to the session's own flag.
public enum AgentFailure {
    /// `code` is Claude Code's `error` on an API error reply ("rate_limit", "invalid_request", "authentication_failed"…).
    public static func classify(_ text: String, code: String? = nil, agent: AgentProvider = .claude, account: String? = nil,
                                at: Timestamp? = nil) -> SessionFailure? {
        let words = text.lowercased()
        let name = agent == .codex ? "Codex" : "Claude"
        if contains(words, gitAuth) {
            return SessionFailure(kind: .gitAuth, message: "GitHub didn't accept the Mac's sign-in for git or gh. Run gh auth login in the session's terminal to go on.",
                                  retryable: false, fix: .terminal, at: at)
        }
        if code == "invalid_request" && words.contains("too long") || contains(words, contextFull) {
            return SessionFailure(kind: .contextFull, message: "The conversation is too long for the model. Compact it or clear it to go on.",
                                  retryable: false, fix: .compact, at: at)
        }
        if code == "authentication_failed" || contains(words, signedOut) {
            let whose = account.map { " for \($0)" } ?? ""
            let message = contains(words, expired)
                ? "\(name)'s login\(whose) has expired. Sign in again at the Mac to go on."
                : "\(name) isn't signed in on the Mac\(account.map { " (\($0))" } ?? ""). Sign in there to go on."
            return SessionFailure(kind: .signedOut, message: message, retryable: false, fix: .atMac, at: at)
        }
        if let folder = deniedFolder(text) {
            return SessionFailure(kind: .folderPermission,
                                  message: "macOS hasn't allowed \(name) into \(folder). Approve it at the Mac, in System Settings › Privacy & Security › Files and Folders.",
                                  retryable: false, fix: .atMac, at: at)
        }
        if code == "rate_limit" || code == "server_error" || contains(words, transient) {
            return SessionFailure(kind: .transient, message: "\(name)'s service failed for a moment. Another try gets past it.",
                                  retryable: true, fix: .wait, at: at)
        }
        return nil
    }

    /// Only a folder macOS's privacy settings can grant, named on the line that was refused: elsewhere in the text a URL
    /// has slashes too, and a path SIP guards (/System, /private/var/db) is nothing Files and Folders can allow.
    public static func deniedFolder(_ text: String) -> String? {
        let kinds: [(String, String)] = [("/library/mobile documents", "iCloud Drive"), ("/desktop", "the Desktop folder"),
                                         ("/documents", "the Documents folder"), ("/downloads", "the Downloads folder"),
                                         ("/pictures/photos library", "the Photos library"), ("/library/mail", "Mail's folder"),
                                         ("/library/messages", "Messages' folder"), ("/volumes/", "a removable or network volume")]
        for line in text.lowercased().split(separator: "\n") where line.contains("operation not permitted") || line.contains("eperm") {
            if let kind = kinds.first(where: { line.contains($0.0) }) { return kind.1 }
        }
        return nil
    }

    private static func contains(_ words: String, _ phrases: [String]) -> Bool { phrases.contains { words.contains($0) } }

    private static let gitAuth = ["gh auth login", "to get started with github cli", "http 401: bad credentials", "authentication failed for 'http",
                                  "permission denied (publickey)", "could not read username for", "invalid username or password",
                                  "gh: authentication required", "requires authentication (http 401)"]
    private static let contextFull = ["prompt is too long", "request too large", "request_too_large", "context_length_exceeded",
                                      "maximum context length", "exceed context limit", "exceeds the context window",
                                      "ran out of room in the model's context window", "input is too long"]
    private static let signedOut = ["invalid api key", "please run /login", "authentication_error", "api error: 401", "not logged in",
                                    "oauth token has expired", "token has been revoked", "you've been signed out", "please log in again",
                                    "refresh_token_expired", "access token could not be refreshed", "run `codex login`", "run codex login"]
    private static let expired = ["expired", "revoked", "could not be refreshed", "signed out"]
    private static let transient = ["overloaded", "api error: 500", "api error: 502", "api error: 503", "api error: 529",
                                    "internal server error", "connection error", "econnreset", "request timed out", "stream disconnected"]
}
