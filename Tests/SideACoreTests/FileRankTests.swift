@testable import SideACore
import Testing

private let paths = [
    "Sources/SideA/SettingsView.swift", "Sources/SideA/SettingsSearch.swift", "Sources/SideACore/Models.swift", "README.md",
    "docs/settings.md", "Tests/SideATests/SettingsSearchTests.swift", "apps/ios/SideARemote/Features/Settings/SettingsView.swift", "Package.swift",
]

/// A name that starts with what was typed comes before one that holds it, then folders, then letters in order.
@Test func aMentionRanksNamesBeforeFolders() {
    #expect(FileRank.matches("settings", in: paths).prefix(3) == ["docs/settings.md", "Sources/SideA/SettingsView.swift", "Sources/SideA/SettingsSearch.swift"])
    #expect(FileRank.matches("readme", in: paths) == ["README.md"])
    #expect(FileRank.matches("sv", in: paths).first == "Sources/SideA/SettingsView.swift")
    #expect(FileRank.matches("zzz", in: paths).isEmpty)
    // With a slash, the folders are what's being typed.
    #expect(FileRank.matches("sidea/set", in: paths).prefix(2) == ["Sources/SideA/SettingsView.swift", "Sources/SideA/SettingsSearch.swift"])
    // Nothing typed: what's nearest the top.
    #expect(FileRank.matches("", in: paths, limit: 2) == ["Package.swift", "README.md"])
    #expect(FileRank.matches("s", in: paths, limit: 3).count == 3)
}
