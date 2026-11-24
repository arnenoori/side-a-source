import Foundation
import Testing
@testable import SideA

private func freshDefaults() throws -> UserDefaults {
    let name = "AppIconChoiceTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Test func theAppIconIsTheDefaultUntilOneIsPicked() throws {
    #expect(AppIconChoice.saved(in: try freshDefaults()) == .defaultChoice)
}

@Test func aPickedAppIconIsRestored() throws {
    let defaults = try freshDefaults()
    let gold = try #require(AppIconChoice.all.first { $0.id == "gold" })
    AppIconChoice.save(gold, in: defaults)
    #expect(AppIconChoice.saved(in: defaults) == gold)
}

@Test func anUnknownAppIconIdFallsBackToTheDefault() throws {
    let defaults = try freshDefaults()
    defaults.set("no-such-icon", forKey: AppIconChoice.key)
    #expect(AppIconChoice.saved(in: defaults) == .defaultChoice)
}

@Test func everyAlternateIconIsBundled() {
    #expect(AppIconChoice.all.count == 7)
    for choice in AppIconChoice.all where choice != .defaultChoice {
        #expect(choice.image != nil, "\(choice.id) is missing from Resources/AppIcons")
    }
    #expect(AppIconChoice.defaultChoice.image == nil)
}
