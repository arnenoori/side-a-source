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
        guard let match = stderr.firstMatch(of: #/(?m)^Side A\[([a-z-]+)\]: /#) else { return (.other, stderr) }
        var message = stderr
        message.replaceSubrange(match.range, with: "Side A: ")
        return (BridgeErrorKind(rawValue: String(match.1)) ?? .other, message)
    }
}

public protocol BridgeError: Error {
    var kind: BridgeErrorKind { get }
}
