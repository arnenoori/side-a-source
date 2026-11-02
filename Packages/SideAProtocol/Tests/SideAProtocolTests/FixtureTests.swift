import CryptoKit
import Foundation
import SideAProtocol
import SideAProtocolFixtures
import Testing

/// Every wire type with fixtures: decode, then encode again.
private let wireTypes: [String: @Sendable (Data) throws -> Data] = {
    func entry<T: Codable>(_: T.Type) -> @Sendable (Data) throws -> Data {
        { try encoder.encode(try JSONDecoder().decode(T.self, from: $0)) }
    }
    return [
        "IslandAction": entry(IslandAction.self), "IslandQuestion": entry(IslandQuestion.self),
        "UsageWindow": entry(UsageWindow.self), "AccountUsage": entry(AccountUsage.self), "RemoteAccount": entry(RemoteAccount.self),
        "RemoteSession": entry(RemoteSession.self), "FinishedSession": entry(FinishedSession.self),
        "RemoteRequest": entry(RemoteRequest.self), "RemoteAnswer": entry(RemoteAnswer.self), "AnswerBody": entry(AnswerBody.self),
        "RequestResolution": entry(RequestResolution.self),
        "RemoteReply": entry(RemoteReply.self), "ReplyResult": entry(ReplyResult.self), "InterruptResult": entry(InterruptResult.self),
        "Upload": entry(Upload.self),
        "ImageRef": entry(ImageRef.self), "FileDiff": entry(FileDiff.self), "TranscriptTool": entry(TranscriptTool.self),
        "TranscriptTodo": entry(TranscriptTodo.self), "TranscriptMessage": entry(TranscriptMessage.self),
        "TranscriptPage": entry(TranscriptPage.self), "TranscriptDelta": entry(TranscriptDelta.self),
        "HostedSession": entry(HostedSession.self), "Worktree": entry(Worktree.self), "StartHosted": entry(StartHosted.self),
        "RemoteProject": entry(RemoteProject.self), "PastSession": entry(PastSession.self),
        "StateSnapshot": entry(StateSnapshot.self), "SessionList": entry(SessionList.self), "RequestList": entry(RequestList.self),
        "HostedList": entry(HostedList.self), "AccountList": entry(AccountList.self), "ProjectList": entry(ProjectList.self),
        "SearchResults": entry(SearchResults.self),
        "ServerEvent": entry(ServerEvent.self), "Welcome": entry(Welcome.self), "EventEnvelope": entry(EventEnvelope.self),
        "ClientMessage": entry(ClientMessage.self),
        "APIError": entry(APIError.self), "ErrorBody": entry(ErrorBody.self),
        "InterruptRequest": entry(InterruptRequest.self), "Handoff": entry(Handoff.self), "RestartRequest": entry(RestartRequest.self),
        "QuitIdleRequest": entry(QuitIdleRequest.self), "QuitIdleResult": entry(QuitIdleResult.self),
        "ListeningPort": entry(ListeningPort.self), "Preview": entry(Preview.self),
        "HistoryPage": entry(HistoryPage.self), "HistoryChange": entry(HistoryChange.self),
        "MacState": entry(MacState.self), "MacSettings": entry(MacSettings.self),
        "CleanupReport": entry(CleanupReport.self), "LeftWorktree": entry(CleanupReport.LeftWorktree.self), "ArchiveRequest": entry(ArchiveRequest.self),
        "CleanupResult": entry(CleanupResult.self), "AutopilotDecision": entry(AutopilotDecision.self), "ApprovalsPage": entry(ApprovalsPage.self), "RequestSummary": entry(RequestSummary.self),
        "AutopilotState": entry(AutopilotState.self), "AutopilotChange": entry(AutopilotChange.self), "Worth": entry(Worth.self), "Incident": entry(Incident.self),
        "HostedAttention": entry(HostedAttention.self),
        "Hello": entry(Hello.self), "Endpoints": entry(Endpoints.self), "MacInfo": entry(MacInfo.self), "DeviceInfo": entry(DeviceInfo.self),
        "PairRequest": entry(PairRequest.self), "PairPending": entry(PairPending.self), "RelayInfo": entry(RelayInfo.self),
        "PairResponse": entry(PairResponse.self), "RekeyRequest": entry(RekeyRequest.self), "RekeyResponse": entry(RekeyResponse.self),
        "NotificationPrefs": entry(NotificationPrefs.self), "PushRegistration": entry(PushRegistration.self),
        "PairingTranscript": entry(PairingTranscript.self),
        "AgentOptions": entry(AgentOptions.self), "ModelOption": entry(ModelOption.self), "OptionsList": entry(OptionsList.self), "SetupStatus": entry(SetupStatus.self),
        "DiagnosticPush": entry(DiagnosticPush.self), "TermControl": entry(TermControl.self),
        "PushPayload": entry(PushPayload.self), "ActivityContentState": entry(ActivityContentState.self), "PushVector": entry(PushVector.self),
        "ConfirmVector": entry(ConfirmVector.self),
        "SessionSettings": entry(SessionSettings.self), "SettingsChange": entry(SettingsChange.self), "SettingsResult": entry(SettingsResult.self),
        "ModelList": entry(ModelList.self), "TurnPlan": entry(TurnPlan.self), "TurnDiff": entry(TurnDiff.self), "ReviewRequest": entry(ReviewRequest.self),
    ]
}()

private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

/// The same JSON with sorted keys and no whitespace, so formatting never counts.
private func canonical(_ data: Data) throws -> String {
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]),
                  as: UTF8.self)
}

private func type(of name: String) -> String { String(name.split(separator: "/").last!.split(separator: ".")[0]) }

/// `kit/` holds what SideARemoteKit keeps in the shared store; its own tests check those.
private let current = Fixtures.names().filter { !$0.hasPrefix("future/") && !$0.hasPrefix("kit/") }

@Test(arguments: current)
func fixtureRoundTrips(_ name: String) throws {
    let roundTrip = try #require(wireTypes[type(of: name)], "\(name) has no wire type")
    let data = try Fixtures.data(name)
    #expect(try canonical(roundTrip(data)) == canonical(data))
}

@Test(arguments: ["qr", "typed-lowercase", "other-spki", "confirm-keys", "unlock-key-only"])
func comparisonCodesMatchTheKnownAnswers(_ name: String) throws {
    let known = try JSONDecoder().decode(PairingTranscript.self, from: Fixtures.data("PairingTranscript.\(name)"))
    let computed = try PairingTranscript(code: known.code, nonce: known.nonce, macPublicKey: known.macPublicKey,
                                         devicePublicKey: known.devicePublicKey, serverKeyHash: known.serverKeyHash, confirmKey: known.confirmKey,
                                         unlockKey: known.unlockKey)
    #expect(computed.comparisonCode == known.comparisonCode && known.comparisonCode.count == 6)
}

@Test func comparisonCodesIgnoreCaseAndDashesButNotKeys() throws {
    let known = try JSONDecoder().decode(PairingTranscript.self, from: Fixtures.data("PairingTranscript.qr"))
    func code(_ pairing: String, spki: String? = nil) throws -> String {
        try PairingTranscript.comparisonCode(code: pairing, nonce: known.nonce, macPublicKey: known.macPublicKey,
                                             devicePublicKey: known.devicePublicKey, serverKeyHash: spki ?? known.serverKeyHash)
    }
    #expect(try code("k7q2 9xmd") == known.comparisonCode)
    #expect(try code("K7Q2-9XMD", spki: Data(repeating: 7, count: 32).base64URL) != known.comparisonCode)
    #expect(PairingTranscript.display("042913") == "042 913")
    // The unlock key alone isn't read as a confirm key.
    let unlockOnly = try JSONDecoder().decode(PairingTranscript.self, from: Fixtures.data("PairingTranscript.unlock-key-only"))
    let swapped = try PairingTranscript.comparisonCode(code: known.code, nonce: known.nonce, macPublicKey: known.macPublicKey,
                                                       devicePublicKey: known.devicePublicKey, serverKeyHash: known.serverKeyHash,
                                                       confirmKey: unlockOnly.unlockKey)
    #expect(swapped != unlockOnly.comparisonCode)
}

@Test func terminalFramesKeepTheirBinaryLayout() throws {
    let output = try Fixtures.binary("TermFrame.output")
    #expect(TermFrame(output)?.data == output)
    if case .output(let bytes)? = TermFrame(output) { #expect(bytes.first == 0x1b) } else { Issue.record("not output") }
    let input = try Fixtures.binary("TermFrame.input")
    #expect(TermFrame(input) == .input(seq: 18, bytes: Data("swift test\r".utf8)))
    #expect(TermFrame(input)?.data == input && TermFrame(Data([0x02, 0])) == nil && TermFrame(Data([9])) == nil)

    // A paste over 16 KiB splits on character boundaries, numbered on.
    let paste = Data(String(repeating: "é", count: 9000).utf8)
    let frames = TermFrame.inputs(paste, from: 7)
    let parts = frames.compactMap { frame -> Data? in if case .input(_, let bytes) = frame { bytes } else { nil } }
    #expect(frames.count == 2 && parts.allSatisfy { $0.count <= TermFrame.maxInput && String(data: $0, encoding: .utf8) != nil })
    #expect(parts.reduce(Data(), +) == paste && frames.last == .input(seq: 8, bytes: parts[1]))
}

/// A fixture that has shipped never changes; new ones are appended to the manifest.
@Test func fixturesAreFrozen() throws {
    let listed = try Fixtures.manifest().split(separator: "\n").reduce(into: [String: String]()) { table, line in
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count == 2 { table[String(parts[1])] = String(parts[0]) }
    }
    for (file, hash) in listed {
        let data = try Data(contentsOf: Fixtures.folder().appendingPathComponent(file))
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == hash, "\(file) changed after it shipped")
    }
    #expect(Set(Fixtures.files()).subtracting(listed.keys).sorted() == [], "add new fixtures to MANIFEST")
}

@Test func unknownValuesFromANewerMacStillDecode() throws {
    let request = try JSONDecoder().decode(RemoteRequest.self, from: Fixtures.data("future/RemoteRequest.unknown-risk-and-kind"))
    #expect(request.risk == .destructive)
    #expect(request.action == .other(tool: "NotebookRun", arguments: #"{"cell":1}"#))
    #expect(request.headline == "Run a notebook cell" && request.answers.contains(AnswerKind(rawValue: "snooze")))

    // A gate this phone doesn't know asks for Face ID; a Mac that sends none asks for an unlocked phone.
    let gated = try JSONDecoder().decode(RemoteRequest.self, from: Fixtures.data("future/RemoteRequest.unknown-gate"))
    #expect(gated.gate?.rawValue == "watchOnly" && gated.allowGate == .biometric)
    #expect(try JSONDecoder().decode(RemoteRequest.self, from: Fixtures.data("RemoteRequest.bash")).allowGate == .unlock)
    #expect(try JSONDecoder().decode(RemoteRequest.self, from: Fixtures.data("RemoteRequest.gate-lock-screen")).allowGate == .lockScreen)

    let bare = try JSONDecoder().decode(IslandAction.self, from: Fixtures.data("future/IslandAction.bare-unknown-kind"))
    #expect(bare == .other(tool: "teleport", arguments: ""))

    // A theme or exit reason this phone doesn't know still decodes, and survives a re-encode.
    let themed = try JSONDecoder().decode(TermControl.self, from: Fixtures.data("future/TermControl.unknown-appearance"))
    #expect(themed == .hello(viewer: "6f1e2d3c-4b5a-4968-8776-655443322110", cols: 80, rows: 24, theme: TermTheme(appearance: .init(rawValue: "sepia"))))
    let exit = try JSONDecoder().decode(TermControl.self, from: Fixtures.data("future/TermControl.exit-unknown-reason"))
    #expect(exit == .exit(status: 137, reason: TermExitReason(rawValue: "evicted")))
    #expect(try JSONDecoder().decode(TermControl.self, from: encoder.encode(exit)) == exit)
    // A phone from before HEALTH pushes sends no `health`: it gets them.
    #expect(try JSONDecoder().decode(NotificationPrefs.self, from: Fixtures.data("future/NotificationPrefs.before-health")).health)
    // An effort this phone doesn't know still decodes, and survives a re-encode.
    let model = try JSONDecoder().decode(ModelOption.self, from: Fixtures.data("future/ModelOption.unknown-effort"))
    #expect(model.efforts.last == Effort(rawValue: "turbo") && model.defaultEffort == .ultra)
    #expect(try JSONDecoder().decode(ModelOption.self, from: encoder.encode(model)) == model)

    // A registration from before bundleID keeps its environment under the old key; one with neither is the App Store app.
    let old = try JSONDecoder().decode(PushRegistration.self, from: Fixtures.data("future/PushRegistration.before-bundle"))
    #expect(old.bundleID == "com.arnenoori.sidea.remote" && old.apnsEnvironment == .sandbox)
    let unlabelled = try JSONDecoder().decode(PushRegistration.self, from: Fixtures.data("future/PushRegistration.bare"))
    #expect(unlabelled.bundleID == PushRegistration.defaultBundleID && unlabelled.apnsEnvironment == .production)

    // An older Mac's per-account worth is ignored.
    var olderAccount = try #require(JSONSerialization.jsonObject(with: Fixtures.data("RemoteAccount.claude")) as? [String: Any])
    olderAccount["worth"] = ["days7": 1, "days30": 2, "currency": "USD"]
    _ = try JSONDecoder().decode(RemoteAccount.self, from: JSONSerialization.data(withJSONObject: olderAccount))

    let session = try JSONDecoder().decode(RemoteSession.self, from: Fixtures.data("future/RemoteSession.new-values"))
    #expect(session.status.rawValue == "napping" && session.abilities.contains(SessionAbility(rawValue: "teleport")))
    // Unknown open-enum values survive a re-encode.
    let again = try JSONDecoder().decode(RemoteSession.self, from: encoder.encode(session))
    #expect(again == session && again.flag?.kind.rawValue == "haunted")

    let event = try JSONDecoder().decode(ServerEvent.self, from: Fixtures.data("future/ServerEvent.unknown-type"))
    #expect(event == .unknown(type: "session.dream") && !event.isState)
    let envelope = try JSONDecoder().decode(EventEnvelope.self, from: Fixtures.data("future/EventEnvelope.unknown-type"))
    #expect(envelope.seq == 43 && envelope.event == .unknown(type: "weather.update"))

    let message = try JSONDecoder().decode(TranscriptMessage.self, from: Fixtures.data("future/TranscriptMessage.new-role"))
    #expect(message.role.rawValue == "thinking" && message.tools.first?.status.rawValue == "paused")

    let account = try JSONDecoder().decode(RemoteAccount.self, from: Fixtures.data("future/RemoteAccount.nulls"))
    #expect(account.usage == nil && account.readAt == nil)
    // Optional fields are left out, never written as null.
    #expect(!String(decoding: try encoder.encode(account), as: UTF8.self).contains("null"))
}

@Test func helloSaysItsVersionBuildAndProtocolInOneLine() throws {
    let hello = try JSONDecoder().decode(Hello.self, from: Fixtures.data("Hello.paired"))
    #expect(hello.versionLine == "0.6.0 (612) · protocol 1")
    #expect(Hello.version("1.0", build: 11) == "1.0 (11)")
}
