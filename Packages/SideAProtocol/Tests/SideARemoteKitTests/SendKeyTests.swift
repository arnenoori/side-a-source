import SideARemoteKit
import Testing

@Test func aKeyIsKeptOnlyForTheSameBodyUntilTheMacAnswers() {
    var key = SendKey<String>("k1")
    #expect(key.sending("go", fresh: "k2") == "k1")
    #expect(key.sending("go", fresh: "k3") == "k1")
    #expect(key.sending("go now", fresh: "k4") == "k4")
    // A refusal is kept against the key on the Mac, so the next send, even of the same words, goes under a new one.
    key.answered(fresh: "k5")
    #expect(key.value == "k5" && key.sending("go now", fresh: "k6") == "k5")
}
