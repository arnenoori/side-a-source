import Foundation
@testable import SideACore
import Testing

@Test(arguments: [
    (#"API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 213456 tokens > 200000 maximum"}}"#, "invalid_request"),
    ("Prompt is too long", nil),
    (#"API Error: 413 {"type":"error","error":{"type":"request_too_large","message":"Request exceeds the maximum size"}}"#, nil),
    ("Codex ran out of room in the model's context window. Start a new thread or clear earlier history before retrying.", nil),
    (#"{"error":{"code":"context_length_exceeded","message":"Your input exceeds the context window of this model."}}"#, nil),
] as [(String, String?)])
func aFullContextIsNotRetriedAndOffersCompact(_ text: String, _ code: String?) throws {
    let failure = try #require(AgentFailure.classify(text, code: code))
    #expect(failure.kind == .contextFull && !failure.retryable && failure.fix == .compact)
}

@Test func signedOutNamesTheAgentAndTheAccount() throws {
    let expired = try #require(AgentFailure.classify(
        #"API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"OAuth token has expired. Please obtain a new token or refresh your existing token."}} · Please run /login"#,
        code: "authentication_failed", account: "Work"))
    #expect(expired.kind == .signedOut && !expired.retryable && expired.fix == .atMac)
    #expect(expired.message == "Claude's login for Work has expired. Sign in again at the Mac to go on.")

    let invalid = try #require(AgentFailure.classify("Invalid API key · Please run /login"))
    #expect(invalid.message == "Claude isn't signed in on the Mac. Sign in there to go on.")

    let codex = try #require(AgentFailure.classify("Your access token could not be refreshed because your refresh token has expired. Please log in again.",
                                                   agent: .codex, account: "Personal"))
    #expect(codex.kind == .signedOut && codex.message.hasPrefix("Codex's login for Personal has expired."))
}

@Test(arguments: [
    ("ls: /Users/you/Desktop: Operation not permitted", "the Desktop folder"),
    ("Error: EPERM: operation not permitted, scandir '/Users/you/Documents/notes'", "the Documents folder"),
    ("cp: /Users/you/Downloads/report.pdf: Operation not permitted", "the Downloads folder"),
    ("find: /Users/you/Library/Mobile Documents/com~apple~CloudDocs: Operation not permitted", "iCloud Drive"),
    ("rsync: opendir \"/Volumes/Backup/photos\" failed: Operation not permitted (1)", "a removable or network volume"),
])
func aRefusedFolderNamesItsKindAndAsksForTheMac(_ text: String, _ folder: String) throws {
    let failure = try #require(AgentFailure.classify(text))
    #expect(failure.kind == .folderPermission && !failure.retryable && failure.fix == .atMac)
    #expect(failure.message.contains(folder) && failure.message.contains("at the Mac"))
}

@Test(arguments: [
    "To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.",
    "HTTP 401: Bad credentials (https://api.github.com/graphql)\nTry authenticating with:  gh auth login",
    "remote: Invalid username or password.\nfatal: Authentication failed for 'https://github.com/you/app.git/'",
    "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.",
    "fatal: could not read Username for 'https://github.com': terminal prompts disabled",
])
func gitAndGhAuthOpenTheTerminal(_ text: String) throws {
    let failure = try #require(AgentFailure.classify(text))
    #expect(failure.kind == .gitAuth && !failure.retryable && failure.fix == .terminal)
}

@Test func onlyLimitsAndServerErrorsAreRetried() throws {
    for code in ["rate_limit", "server_error"] {
        #expect(try #require(AgentFailure.classify("API Error: Request was aborted.", code: code)).retryable)
    }
    #expect(try #require(AgentFailure.classify(#"API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)).retryable)
    for text in ["Prompt is too long", "Invalid API key · Please run /login", "Operation not permitted /Users/you/Desktop", "gh auth login"] {
        #expect(AgentFailure.classify(text, code: "rate_limit")?.retryable == false, "\(text)")
    }
    #expect(AgentFailure.classify("Tests failed: 3 of 120") == nil)
}

@Test(arguments: [
    "cat: /private/var/db/foo: Operation not permitted",
    "kill: operation not permitted /x",
    "EPERM: operation not permitted\nsee https://example.com/docs/Desktop",
])
func aRefusalNoPrivacySettingCanGrantIsNoFolderFailure(_ text: String) {
    #expect(AgentFailure.deniedFolder(text) == nil)
    #expect(AgentFailure.classify(text)?.kind != .folderPermission)
}

@Test func keysAndTokensNeverLeaveTheMac() {
    // Spliced in, so the samples are whole at run time and the public-source scan sees no key in this file.
    let cut = ""
    let cases: [(String, String)] = [
        ("Invalid API key sk-ant\(cut)-api03-AbCdEf0123456789_xyzXYZ-0123", "sk-ant-"),
        ("OPENAI_API_KEY=sk-proj-0123456789abcdefghijABCDEFGHIJ is invalid", "0123456789abcdef"),
        ("remote: https://you:ghp_0123456789abcdefghijABCDEFGHIJ0123@github.com/you/app.git", "ghp_"),
        ("token ghs_0123456789abcdefghijABCDEFGHIJ rejected", "ghs_"),
        ("github_pat\(cut)_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz", "github_pat_"),
        ("Authorization: Bearer abc.def-ghi_jkl0123456789", "abc.def"),
        (#"{"access_token":"ya29.a0Af_secret_value_here","expires_in":3599}"#, "ya29"),
        ("password = hunter2hunter2", "hunter2"),
        ("aws AKIA\(cut)IOSFODNN7EXAMPLE", "AKIA\(cut)IOSFODNN7EXAMPLE"),
        ("slack xoxb\(cut)-123456789012-abcdefghij", "xoxb-1234"),
        ("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", "eyJhbGci"),
        ("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----", "b3BlbnNzaC1"),
        ("Authorization: Basic dXNlcjpwYXNz", "dXNlcjpwYXNz"),
        ("authorization: Token abc123secret", "abc123secret"),
        (#"Authorization: Digest username="me", realm="x", nonce="n0nce", response="6629fae49393a05397450978507c4ef1""#, "6629fae4"),
        ("clone https://ghp0123456789token@github.com/you/app.git", "ghp0123456789token"),
        ("aws ASIAIOSFODNN7EXAMPLE", "ASIAIOSFODNN7EXAMPLE"),
        ("stripe sk_live\(cut)_0123456789abcdefABCDEF", "0123456789abcdef"),
        ("stripe sk_test_0123456789abcdefABCDEF", "0123456789abcdef"),
        ("stripe rk_live\(cut)_0123456789abcdefABCDEF", "0123456789abcdef"),
        ("-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQOYBF0123456789\n-----END PGP PRIVATE KEY BLOCK-----", "lQOYBF0123456789"),
    ]
    for (text, secret) in cases {
        let redacted = Redact.secrets(text)
        #expect(!redacted.contains(secret) && redacted.contains(Redact.mark), "\(text) → \(redacted)")
    }
    let plain = "Prompt is too long: 213456 tokens > 200000 maximum in /Users/you/code/app at commit 3f2a9c1d"
    #expect(Redact.secrets(plain) == plain)
    #expect(Redact.secrets("fatal: Authentication failed for 'https://github.com/you/app.git/'") == "fatal: Authentication failed for 'https://github.com/you/app.git/'")
}
