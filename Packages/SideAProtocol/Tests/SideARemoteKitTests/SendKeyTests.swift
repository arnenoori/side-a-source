import SideARemoteKit
import Testing

@Test func aKeyIsKeptOnlyForTheSameBodyUntilTheMacAnswers() {
    var key = SendKey<String>("k1")
    #expect(key.sending("go", fresh: "k2") == "k1")
    #expect(key.sending("go", fresh: "k3") == "k1")
    #expect(key.sending("go now", fresh: "k4") == "k4")
    key.answered(fresh: "k5")
    #expect(key.value == "k5" && key.sending("go now", fresh: "k6") == "k5")
}
