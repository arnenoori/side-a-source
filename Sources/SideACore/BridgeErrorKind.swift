import Foundation

/// What a failed bridge run means for its account, from the code the bridge prints as `Side A[code]: …` on stderr.
/// The message names the account, so its words never decide this.
public enum BridgeErrorKind: String, Sendable {
    case signIn = "signin"
    case idle
    case rateLimited = "rate-limited"
    case unconfirmed
    case other

    public init(_ error: any Error) {
        self = (error as? any BridgeError)?.kind ?? .other
    }

    /// The kind, and the stderr with its code taken out, as people read it.
    public static func parse(_ stderr: String) -> (kind: BridgeErrorKind, message: String) {
        let parsed = details(stderr)
        return (parsed.kind, parsed.message)
    }

    /// `parse`, and whose login replaced the account's when the bridge says so on a line of its own,
    /// `Side A[replaced-by]: "owner@example.com"`. That line isn't part of the message.
    public static func details(_ stderr: String) -> (kind: BridgeErrorKind, message: String, replacedBy: String?) {
        var text = stderr
        var owner: String?
        if let line = text.firstMatch(of: #/(?m)^Side A\[replaced-by\]: (.*)(\n|$)/#) {
            owner = try? JSONDecoder().decode(String.self, from: Data(line.1.utf8))
            text.removeSubrange(line.range)
            if text.hasSuffix("\n") { text.removeLast() }
        }
        guard let match = text.firstMatch(of: #/(?m)^Side A\[([a-z-]+)\]: /#) else { return (.other, text, owner) }
        text.replaceSubrange(match.range, with: "Side A: ")
        return (BridgeErrorKind(rawValue: String(match.1)) ?? .other, text, owner)
    }

    /// Whose login replaced an account's, from a failed run: what the bridge said apart from the words, or, from a bridge
    /// that only had the words, "its saved login is now someone@example.com's.".
    public static func replacement(in error: any Error) -> String? {
        if let owner = (error as? any BridgeError)?.replacedBy { return owner }
        return error.localizedDescription.firstMatch(of: #/login is now (.+)'s\./#).map { String($0.1) }
    }
}

public protocol BridgeError: Error {
    var kind: BridgeErrorKind { get }
    /// Whose login took the account's place, when the bridge said.
    var replacedBy: String? { get }
}

public extension BridgeError {
    var replacedBy: String? { nil }
}
