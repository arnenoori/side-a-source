import Foundation

public extension Capability {
    /// Listed whether or not the Mac has a key: `transcribe_no_key` says it hasn't, so the phone can say why it fell back.
    static let transcribe = Self(rawValue: "transcribe")
}

public extension ErrorCode {
    static let transcribeNoKey = Self(rawValue: "transcribe_no_key")
    static let transcribeKeyRefused = Self(rawValue: "transcribe_key_refused")
    static let transcribeUnreachable = Self(rawValue: "transcribe_unreachable")
    static let transcribeFailed = Self(rawValue: "transcribe_failed")
    static let transcribeTooLong = Self(rawValue: "transcribe_too_long")
    /// 429: this phone's last recording is still being transcribed, or it has sent its hourly allowance.
    static let transcribeLimited = Self(rawValue: "transcribe_limited")
}

/// The body is the recording itself, never JSON. No Idempotency-Key: the Mac records a keyed answer on its disk, and
/// these words must not be kept.
public enum TranscribeRoute {
    public static let path = "/v1/transcribe"
    public static let longest: TimeInterval = 300
    public static let hintLimit = 300
    public static let largest = 4 << 20
    /// The phone's wait, longer than the Mac's own: listing the session's files, then the provider.
    public static let timeout: TimeInterval = 100
    public static let macListing: TimeInterval = 5
    public static let macProvider: TimeInterval = 90
}

public struct TranscribeAsk: Hashable, Sendable {
    public var session: SessionKey?
    public var language: String?
    public var hint: String?
    /// For the Mac's log, which keeps only length, size and outcome.
    public var seconds: Int?

    public init(session: SessionKey? = nil, language: String? = nil, hint: String? = nil, seconds: Int? = nil) {
        self.session = session; self.language = language; self.hint = hint; self.seconds = seconds
    }

    public var query: [URLQueryItem] {
        [("session", session), ("language", language), ("hint", hint.map { String($0.prefix(TranscribeRoute.hintLimit)) }), ("seconds", seconds.map(String.init))]
            .compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
    }

    public init(query: [String: String]) {
        session = query["session"]; language = query["language"]; hint = query["hint"].map { String($0.prefix(TranscribeRoute.hintLimit)) }
        seconds = query["seconds"].flatMap(Int.init)
    }
}

public struct TranscribeResult: Codable, Hashable, Sendable {
    public let text: String
    public init(text: String) { self.text = text }
}
