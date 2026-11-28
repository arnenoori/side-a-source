import Foundation
@testable import SideASessionKit
import SideAProtocol
import Testing

@Test func anAtWordAtTheCaretNamesAFile() {
    let text = "look at @Sour and mail me@example.com"
    let found = FileMentions.word(in: text, caret: 13)
    #expect(found?.query == "Sour" && found?.range == NSRange(location: 8, length: 5))
    #expect(FileMentions.word(in: "@", caret: 1)?.query.isEmpty == true)
    #expect(FileMentions.word(in: text, caret: text.utf16.count) == nil)
    #expect(FileMentions.word(in: text, caret: 4) == nil)
    #expect(FileMentions.word(in: "@a b", caret: 4) == nil)
}

@Test func aChosenFileTakesTheWordsPlace() {
    let range = NSRange(location: 8, length: 5)
    var applied = FileMentions.apply("Sources/App/Main.swift", agent: .claude, to: "look at @Sour and", at: range)
    #expect(applied.text == "look at @Sources/App/Main.swift and" && applied.caret == 32)
    applied = FileMentions.apply("Sources/App/Main.swift", agent: .codex, to: "look at @Sour", at: range)
    #expect(applied.text == "look at Sources/App/Main.swift " && applied.caret == applied.text.utf16.count)
    applied = FileMentions.apply("docs/my notes.md", agent: .claude, to: "@", at: NSRange(location: 0, length: 1))
    #expect(applied.text == "@\"docs/my notes.md\" ")
    let row = FileMentions.Row(path: "Sources/App/Main.swift")
    #expect(row.name == "Main.swift" && row.folder == "Sources/App" && FileMentions.Row(path: "README.md").folder.isEmpty)
}
