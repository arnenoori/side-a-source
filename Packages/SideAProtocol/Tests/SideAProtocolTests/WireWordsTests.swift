import SideAProtocol
import Testing

// Both apps and the relay match these byte for byte; an older phone or Mac still sends the old spelling.
@Test func wireWordsKeepTheirSpelling() {
    #expect(ScreenControlReason.focus.rawValue == "focus")
    #expect(ErrorCode.transcribeLimited.rawValue == "transcribe_limited")
    #expect(FileRefusal.outside.rawValue == "outside" && FileRefusal.secret.rawValue == "secret" && FileRefusal.linked.rawValue == "linked")
    #expect(ReplyMark.statusPrefix == "status ")
    let categories: [(PushCategory, String)] = [
        (.requestSafe, "REQUEST_SAFE"), (.request, "REQUEST"), (.requestDestructive, "REQUEST_DESTRUCTIVE"), (.question, "QUESTION"),
        (.questionOpen, "QUESTION_OPEN"), (.plan, "PLAN"), (.finished, "FINISHED"), (.finishedFaceID, "FINISHED_FACE_ID"),
        (.limit, "LIMIT"), (.health, "HEALTH"), (.rotation, "ROTATION"), (.macQuiet, "MAC_QUIET"), (.test, "TEST"), (.answered, "ANSWERED"), (.open, "OPEN"),
    ]
    for (category, raw) in categories { #expect(category.rawValue == raw) }
}

@Test func aStopsReasonNamesTheAgentAndIsKnownByThePhone() {
    #expect(ReplyReceipt.stopped(agent: .claude) == "Stopped before Claude read it.")
    #expect(ReplyReceipt.stopped(agent: .codex) == "Stopped before Codex read it.")
    #expect(ReplyReceipt.isStopReason(ReplyReceipt.stopped(agent: .codex)))
    #expect(!ReplyReceipt.isStopReason("The interrupt stopped Codex before it read it."))
    #expect(!ReplyReceipt.isStopReason("Claude let go of it unread."))
}

@Test func aSessionIsNamedByItsTurnsAndOnlyWithoutOneByItsStatus() {
    func session(_ turn: String?) -> RemoteSession {
        RemoteSession(id: "s", agent: .claude, title: "t", project: "p", status: .working, statusAt: 7, turnID: turn)
    }
    let finished = FinishedSession(sessionID: "s", turnID: "f1", title: "t", summary: "", at: 8, canFollowUp: true)
    #expect(ReplyMark.marks(session("t1"), finished) == ["t1", "f1"])
    #expect(ReplyMark.marks(session(nil), nil) == ["status 7.0"])
    #expect(ReplyMark.marks(nil, nil).isEmpty)
}
