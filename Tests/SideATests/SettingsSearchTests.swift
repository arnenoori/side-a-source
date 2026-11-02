@testable import SideA
import Testing

@Test func settingsSearchMatchesEveryTermAcrossTitleTabAndWords() {
    #expect(SettingsEntry.matching("").isEmpty)
    #expect(SettingsEntry.matching("   ").isEmpty)
    #expect(SettingsEntry.matching("uninstall").map(\.title) == ["Remove Side A"])
    #expect(SettingsEntry.matching("NOTCH sound").isEmpty)
    #expect(SettingsEntry.matching("autopilot fable").map(\.title) == ["Follow Fable"])
    #expect(SettingsEntry.matching("tmux").first?.tab == .setup)
}

@Test func everySettingsTabHasSomethingToFind() {
    for tab in SettingsTab.allCases {
        #expect(SettingsEntry.all.contains { $0.tab == tab })
    }
}
