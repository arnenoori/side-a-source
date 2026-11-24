@testable import SideA
import Testing

private func titles(_ query: String) -> [String] { SettingsEntry.matching(query).map(\.title) }

@Test func settingsSearchMatchesEveryTermAcrossTitleTabAndWords() {
    #expect(SettingsEntry.matching("").isEmpty)
    #expect(SettingsEntry.matching("   ").isEmpty)
    #expect(titles("caffeinate") == ["Keep awake while agents work"])
    #expect(titles("autopilot fable") == ["Follow Fable"])
    #expect(SettingsEntry.matching("tmux").first?.tab == .setup)
}

@Test func settingsSearchFindsAWordAsItIsTyped() {
    #expect(titles("upd").first == "Updates")
    #expect(titles("notif").allSatisfy { title in SettingsEntry.all.first { $0.title == title }?.tab == .notifications })
    #expect(titles("PRIV") == ["Privacy"])
}

@Test func settingsSearchForgivesTypos() {
    #expect(titles("updtaes").first == "Updates")
    #expect(titles("privcy").first == "Privacy")
    #expect(titles("cafeinate") == ["Keep awake while agents work"])
    #expect(titles("autopliot").first == "Autopilot")
    #expect(titles("xyz").isEmpty)
    #expect(titles("qqqqqq").isEmpty)
}

@Test func settingsSearchReadsWordsRunTogetherAndPunctuation() {
    #expect(titles("menubar").first == "Show only in the menu bar")
    #expect(titles("5 hour").first == "Move at")
    #expect(titles("login").contains("Open at login"))
}

@Test func settingsSearchPutsTheTitleFirst() {
    let pool = titles("pool")
    #expect(Set(pool.prefix(2)) == ["Pool mode", "Test Pool"])
    #expect(titles("island").prefix(2) == ["Dynamic Island", "Island shortcuts"])
}

@Test func settingsSearchShowsTheNearestWhenNothingHasEveryTerm() {
    let near = titles("notch zzzzzz")
    #expect(!near.isEmpty)
    #expect(near.allSatisfy { title in SettingsEntry.all.first { $0.title == title }?.tab == .notifications })
}

@Test func settingsSearchMarksWhatWasTyped() {
    let entry = SettingsEntry(title: "Dynamic Island", tab: .notifications)
    let bold = entry.highlighted("isl").runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
    #expect(bold.count == 1)
    #expect(bold.first.map { String(entry.highlighted("isl")[$0.range].characters) } == "Isl")
}

@Test func everySettingsTabHasSomethingToFind() {
    for tab in SettingsTab.allCases {
        #expect(SettingsEntry.all.contains { $0.tab == tab })
    }
}
