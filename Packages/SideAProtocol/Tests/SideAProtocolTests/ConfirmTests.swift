import Foundation
import SideAProtocol
import SideAProtocolFixtures
import Testing

/// Known-answer signatures from two fixed P-256 keys, made outside Swift.
struct ConfirmVector: Codable {
    struct Case: Codable {
        let name, purpose, subject, message, header: String
        let answer: RemoteAnswer?
    }
    let confirmPrivateKey, confirmKey, unlockPrivateKey, unlockKey, macID, deviceID, requestID, sessionID: String
    let at: Int
    let keys: [Key]
    let cases: [Case]
}

private func vector() throws -> ConfirmVector {
    try JSONDecoder().decode(ConfirmVector.self, from: Fixtures.data("ConfirmVector.signatures"))
}

@Test func bothSidesBuildTheKnownSubjectsAndMessages() throws {
    let v = try vector()
    for c in v.cases {
        let subject = try c.answer.map { try #require(try ConfirmMessage.subject(requestID: v.requestID, answer: $0)) }
            ?? (c.purpose == "keys" ? ConfirmMessage.subject(sessionID: v.sessionID, keys: v.keys) : ConfirmMessage.subject(terminal: c.subject))
        #expect(subject == c.subject, "\(c.name)")
        #expect(try ConfirmMessage.text(macID: v.macID, deviceID: v.deviceID, purpose: ConfirmPurpose(rawValue: c.purpose), subject: subject, at: v.at)
                == c.message, "\(c.name)")
    }
}

@Test func theKnownSignaturesVerifyWithTheirOwnKeyOnly() throws {
    let v = try vector()
    #expect(Set(v.cases.compactMap { ConfirmSignature(header: $0.header)?.signer }) == [.confirm, .unlock])
    for c in v.cases {
        let signature = try #require(ConfirmSignature(header: c.header))
        #expect(signature.headerValue == c.header)
        let own = signature.signer == .confirm ? v.confirmKey : v.unlockKey
        func verify(key: String? = nil, purpose: String = c.purpose, subject: String = c.subject, deviceID: String? = nil, now: Int? = nil) -> Bool {
            signature.verify(publicKey: key ?? own, macID: v.macID, deviceID: deviceID ?? v.deviceID, purpose: ConfirmPurpose(rawValue: purpose),
                             subject: subject, now: Double(now ?? v.at))
        }
        #expect(verify(), "\(c.name)")
        #expect(verify(now: v.at + 120) && verify(now: v.at - 120) && !verify(now: v.at + 121) && !verify(now: v.at - 121))
        #expect(!verify(key: signature.signer == .confirm ? v.unlockKey : v.confirmKey))
        #expect(!verify(subject: c.subject + "x") && !verify(deviceID: "other") && !verify(purpose: c.purpose == "keys" ? "terminal" : "keys"))
    }
}

@Test func fieldsThatWouldBlurTheMessageAreRefused() throws {
    #expect(throws: ConfirmMessage.Invalid.newline("subject")) {
        try ConfirmMessage.text(macID: "m", deviceID: "d", purpose: .terminal, subject: "a\nb", at: 1)
    }
    #expect(throws: ConfirmMessage.Invalid.separator("requestID")) { try ConfirmMessage.subject(requestID: "a:b", answer: .allow(confirmDestructive: false)) }
    #expect(throws: ConfirmMessage.Invalid.separator("sessionID")) { try ConfirmMessage.subject(sessionID: "a:b", keys: [.enter]) }
    #expect(throws: ConfirmMessage.Invalid.separator("sessionID")) { try ConfirmMessage.subject(sessionID: "a:b", settings: SettingsChange(mode: .plan)) }
    #expect(throws: ConfirmMessage.Invalid.separator("requestID")) { try ConfirmMessage.subject(requestID: "a:b", allowMode: .auto) }
    #expect(throws: ConfirmMessage.Invalid.separator("accountID")) { try ConfirmMessage.subject(useAccount: "a:b") }
    #expect(throws: ConfirmMessage.Invalid.separator("name")) { try ConfirmMessage.subject(trust: "a:b", cwd: "/x") }
    for bad in ["v2.1.c.AAAA", "v1.x.c.AAAA", "v1.1.x.AAAA", "v1.1.c.", "v1.1.AAAA", "v1.1.c.AA.AA"] {
        #expect(ConfirmSignature(header: bad) == nil, "\(bad)")
    }
}

@Test func denyAndTerminalNeedNoSignature() throws {
    #expect(try ConfirmMessage.subject(requestID: "r1", answer: .deny(message: nil)) == nil)
    #expect(try ConfirmMessage.subject(requestID: "r1", answer: .terminal) == nil)
}

@Test func confirmErrorsSayWhichKeyAndWhenToPairAgain() throws {
    let required = try JSONDecoder().decode(APIError.self, from: Fixtures.data("APIError.confirm-required"))
    #expect(required.code == .confirmRequired && required.confirmLevel == .biometric && !required.pairAgain)
    let again = try JSONDecoder().decode(APIError.self, from: Fixtures.data("APIError.confirm-pair-again"))
    #expect(again.code == .confirmInvalid && again.confirmLevel == .unlock && again.pairAgain)
}

private let knownSubjects: [(String, @Sendable () throws -> String, String)] = [
    ("account", { try ConfirmMessage.subject(useAccount: "acct-1") }, "acct-1:use"),
    ("autopilot off", { ConfirmMessage.subject(autopilot: AutopilotChange(enabled: false)) }, "enabled:false"),
    ("autopilot on", { ConfirmMessage.subject(autopilot: AutopilotChange(enabled: true)) }, "enabled:true"),
    ("answers on", { ConfirmMessage.subject(autopilotAnswers: AutopilotChange(enabled: true)) }, "answers:enabled:true"),
    ("answers off", { ConfirmMessage.subject(autopilotAnswers: AutopilotChange(enabled: false)) }, "answers:enabled:false"),
    ("allow and switch mode", { try ConfirmMessage.subject(requestID: "r1", allowMode: .acceptEdits) }, "r1:allowMode:acceptEdits"),
    ("settings", { try ConfirmMessage.subject(sessionID: "s1", settings: SettingsChange(mode: .plan)) }, "s1:D1aWkmhvzkfb4ehLzkd0M8fM8tk_GBqeAV7pNf_68kE"),
    // The Mac hashes the change it decoded, so the wire's spelling and the value's agree.
    ("settings as sent", {
        try ConfirmMessage.subject(sessionID: "s1", settings: JSONDecoder().decode(SettingsChange.self, from: Fixtures.data("SettingsChange.mode-raise")))
    }, "s1:IGN-KBPsi6JQoZh4nhWjOykqCCVLOgaIWVjv3kImHiI"),
    ("settings as built", { try ConfirmMessage.subject(sessionID: "s1", settings: SettingsChange(mode: .bypassPermissions)) }, "s1:IGN-KBPsi6JQoZh4nhWjOykqCCVLOgaIWVjv3kImHiI"),
    ("start", { try ConfirmMessage.subject(start: JSONDecoder().decode(StartHosted.self, from: Fixtures.data("StartHosted.permission-mode"))) }, "start:HUkUzfWMQV_fGcW3OW5ftlfHhkEHusiDJACEcz5FBJk"),
    ("trust", { try ConfirmMessage.subject(trust: "sa-app-3f9c", cwd: "/Users/you/code/app") }, "sa-app-3f9c:iMSZSkfzECyK1--QVeqRUSCe_4b9z0N9S2fQMAyE0v4"),
    ("trust elsewhere", { try ConfirmMessage.subject(trust: "sa-app-3f9c", cwd: "/Users/you/code/app/other") }, "sa-app-3f9c:WiUQtcQny3x_nWY_mO1WS9DrP1dyDaP8_KFfQaRUBOU"),
]

@Test(arguments: knownSubjects)
func subjectsHaveTheirKnownForm(_ name: String, _ subject: @Sendable () throws -> String, _ expected: String) throws {
    let built = try subject()
    #expect(built == expected, "\(name): \(built)")
}
