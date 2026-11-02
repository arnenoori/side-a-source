import Foundation
@testable import SideACore
import SideAProtocol
import Testing

@Test func inputFramesAreWrittenOnceInOrder() {
    var input = RemoteTerminal.Input()
    #expect(input.take(seq: 1, bytes: Data("l".utf8)) == .write(Data("l".utf8)))
    #expect(input.take(seq: 2, bytes: Data("s".utf8)) == .write(Data("s".utf8)))
    // A resent frame after a reconnect is acked again, never typed twice.
    #expect(input.take(seq: 2, bytes: Data("s".utf8)) == .again && input.applied == 2)
    #expect(input.take(seq: 4, bytes: Data("x".utf8)) == .gap && input.applied == 2)
    #expect(input.take(seq: 3, bytes: Data(count: TermFrame.maxInput + 1)) == .tooLarge && input.applied == 3)
    #expect(input.take(seq: 4, bytes: Data("\r".utf8)) == .write(Data("\r".utf8)))
}

@Test func theMacOwnsTheWindowWhileItTyped() {
    let now: TimeInterval = 1_000
    let phones = [RemoteTerminal.Phone(cols: 50, rows: 30, active: 900), RemoteTerminal.Phone(cols: 60, rows: 40, active: 990)]
    #expect(RemoteTerminal.size(phones: [], macActivity: [now], now: now) == .free)
    #expect(RemoteTerminal.size(phones: phones, macActivity: [now - 30], now: now) == .mac)
    #expect(RemoteTerminal.size(phones: phones, macActivity: [now - 61], now: now) == .phone(cols: 60, rows: 40))
    #expect(RemoteTerminal.size(phones: phones, macActivity: [], now: now).owner == "phone")
    #expect(RemoteTerminal.clamp(cols: 2, rows: 9_999) == (10, 200))
}

@Test func startupQueriesAreAnsweredAndKeptFromThePhone() {
    var queries = RemoteTerminal.Queries(dark: false)
    let esc = "\u{1B}"
    let (forward, replies) = queries.filter(Data("hi\(esc)[c\(esc)[>q\(esc)[1mbold\(esc)]11;?\u{07}".utf8))
    #expect(String(decoding: forward, as: UTF8.self) == "hi\(esc)[1mbold")
    #expect(String(decoding: replies, as: UTF8.self) == "\(esc)[?62;22c\(esc)P>|SideA-Remote 1.0\(esc)\\\(esc)]11;rgb:0000/0000/0000\u{07}")
    // Cut across two reads: held, then answered.
    let first = queries.filter(Data("ok\(esc)[?99".utf8))
    #expect(String(decoding: first.forward, as: UTF8.self) == "ok" && first.replies.isEmpty)
    let second = queries.filter(Data("6n!".utf8))
    #expect(String(decoding: second.forward, as: UTF8.self) == "!" && String(decoding: second.replies, as: UTF8.self) == "\(esc)[?997;2n")
    // A lone Esc at the end is held only while it could start a query.
    #expect(queries.filter(Data(esc.utf8)).forward.isEmpty)
    #expect(queries.flush() == Data(esc.utf8))
}

@Test func thePhonesThemeAnswersTheColourQueries() {
    #expect(RemoteTerminal.Queries.colour("#1C1c1e") == "rgb:1c1c/1c1c/1e1e")
    #expect(RemoteTerminal.Queries.colour("1c1c1e") == nil && RemoteTerminal.Queries.colour("#1c1c1g") == nil)
    var light = RemoteTerminal.Queries(theme: TermTheme(appearance: .light, bg: "#fafafa"))
    let asked = light.filter(Data("\u{1B}[?996n\u{1B}]11;?\u{07}\u{1B}]10;?\u{1B}\\".utf8))
    #expect(asked.forward.isEmpty)
    #expect(String(decoding: asked.replies, as: UTF8.self) == "\u{1B}[?997;2n\u{1B}]11;rgb:fafa/fafa/fafa\u{07}\u{1B}]10;rgb:0000/0000/0000\u{1B}\\")
    var none = RemoteTerminal.Queries(theme: nil)
    #expect(String(decoding: none.filter(Data("\u{1B}[?996n".utf8)).replies, as: UTF8.self) == "\u{1B}[?997;1n")
}
