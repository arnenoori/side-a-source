import Foundation
@testable import SideACore
import Testing

private struct Failure: BridgeError, LocalizedError {
    var kind: BridgeErrorKind = .signIn
    var message: String
    var errorDescription: String? { message }
}

@Test func theOwnerOfAReplacedLoginComesApartFromTheWords() {
    let new = BridgeErrorKind.details("Side A[signin]: Sign in to Work again; its saved login is now me@example.com's.\nSide A[replaced-by]: \"me@example.com\"\n")
    #expect(new.kind == .signIn && new.replacedBy == "me@example.com")
    #expect(new.message == "Side A: Sign in to Work again; its saved login is now me@example.com's.")
    // Without the extra line, the words are all there is, as an older bridge printed them.
    let old = BridgeErrorKind.details("Side A[signin]: Sign in to Work again; its saved login is now me@example.com's.\n")
    #expect(old.kind == .signIn && old.replacedBy == nil && old.message.hasSuffix("is now me@example.com's.\n"))
    #expect(BridgeErrorKind.parse("Side A[idle]: Login idle.") == (.idle, "Side A: Login idle."))
}

@Test func anOwnerWithPunctuationSurvivesEitherWay() {
    for owner in ["o'brien@example.com", "a+b's@example.com", "quote\"d@example.com", "ünï@example.com", "x@y.com's.z"] {
        let encoded = String(decoding: (try? JSONEncoder().encode(owner)) ?? Data(), as: UTF8.self)
        let words = "Side A[signin]: Sign in to Work again; its saved login is now \(owner)'s."
        let parsed = BridgeErrorKind.details(words + "\nSide A[replaced-by]: \(encoded)")
        #expect(parsed.replacedBy == owner && parsed.message == words.replacing("Side A[signin]: ", with: "Side A: "))
        // The structured owner wins over whatever the words could be read as.
        #expect(BridgeErrorKind.replacement(in: PoolBridge.Failure(stderr: words + "\nSide A[replaced-by]: \(encoded)")) == owner)
        // And the words alone still give it, for a bridge that sends no such line.
        #expect(BridgeErrorKind.replacement(in: PoolBridge.Failure(stderr: words)) == owner)
    }
}

@Test func anAccountNamedLikeTheWordsIsNotAReplacement() {
    let plain = PoolBridge.Failure(stderr: "Side A[signin]: Sign in to login is now x's. again.")
    // The words alone can't tell the difference: that is why the bridge says it apart.
    #expect(BridgeErrorKind.replacement(in: plain) == "x")
    let said = PoolBridge.Failure(stderr: "Side A[signin]: Sign in to login is now x's. again; its saved login is now y@example.com's.\nSide A[replaced-by]: \"y@example.com\"")
    #expect(BridgeErrorKind.replacement(in: said) == "y@example.com")
    #expect(BridgeErrorKind.replacement(in: Failure(message: "Sign in to Work again.")) == nil)
    #expect(BridgeErrorKind.replacement(in: PoolBridge.Failure(stderr: "Side A[signin]: Sign in to Work again.")) == nil)
}
