import CryptoKit
import Foundation
import SideAProtocol
import Testing

@Test func questionAnswersJoinPickedLabelsThenTypedText() {
    let question = IslandQuestion(question: "Which platforms?", header: nil,
                                  options: [.init(label: "iOS (Recommended)", description: nil), .init(label: "macOS", description: nil)],
                                  multiSelect: true)
    #expect(question.answerText(picked: ["iOS (Recommended)", "macOS"], other: "  visionOS \n") == "iOS (Recommended), macOS, visionOS")
    #expect(question.answerText(picked: [], other: " ") == "")
    #expect(question.options[0].recommended && question.options[0].title == "iOS" && !question.options[1].recommended)
}

@Test func requestTextDefaultsToTheActionsOwn() {
    let request = RemoteRequest(id: "r", agent: .claude, tool: "Edit", action: .patch(files: ["a/b.swift"], text: ""), risk: .normal,
                                answers: [.allow, .deny], title: "app", arrivedAt: 1)
    #expect(request.headline == "Edit b.swift" && request.detail == "a/b.swift")
    #expect(IslandAction.fetch("https://example.com/x").headline == "Fetch example.com")
}

@Test func setsEncodeTheSameWayEveryTime() throws {
    let session = RemoteSession(id: "s", agent: .claude, title: "t", project: "p", status: .idle,
                                abilities: [.transcript, .note, .interrupt, .followUp, .end, .terminal])
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let text = String(decoding: try encoder.encode(session), as: UTF8.self)
    #expect(text.contains(#""abilities":["end","followUp","interrupt","note","terminal","transcript"]"#))
}

@Test func anUnknownRiskDecodesAsDestructive() throws {
    #expect(try JSONDecoder().decode([IslandRisk].self, from: Data(#"["whatever"]"#.utf8)) == [.destructive])
}

@Test func theKeyPinIsTheHashOfTheSubjectPublicKeyInfo() throws {
    let key = P256.Signing.PrivateKey().publicKey
    // CryptoKit's DER is the full SPKI, so both routes agree.
    #expect(SPKI.hash(p256: key.x963Representation) == SPKI.hash(key))
    #expect(SPKI.hash(p256: Data(count: 65)) == nil)
    #expect(SPKI.keyID(SPKI.hash(key))?.count == 16)
}
