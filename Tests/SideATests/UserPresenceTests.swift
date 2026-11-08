import Testing
@testable import SideA

struct UserPresenceTests {
    @Test func recentInputOnAnUnlockedScreenIsAtTheMac() {
        #expect(UserPresence(idle: 5, locked: false).atMac(within: 60))
        #expect(!UserPresence(idle: 5, locked: false).away(for: 600))
    }

    @Test func aLockedScreenIsAwayWhateverTheInput() {
        #expect(!UserPresence(idle: 1, locked: true).atMac(within: 60))
        #expect(UserPresence(idle: 1, locked: true).away(for: 600))
    }

    @Test func longIdleIsAway() {
        #expect(!UserPresence(idle: 60, locked: false).atMac(within: 60))
        #expect(UserPresence(idle: 600, locked: false).away(for: 600))
    }
}
