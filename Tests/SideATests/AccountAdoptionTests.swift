import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

@MainActor private final class MacLogins {
    let store = AccountStore(demo: true)
    var claude = "", codex = ""
    var adopted: [String] = []
    var adoptFails = false
    init() {
        store.config.accounts = []; store.config.selectedID = nil; store.activeIDs = [:]
        store.testBridge = { args in
            switch args.first {
            case "active":
                let accounts = self.store.config.accounts
                let claudeID = accounts.first { $0.provider == .claude && !self.claude.isEmpty && $0.email.caseInsensitiveCompare(self.claude) == .orderedSame }?.id
                let codexID = accounts.first { $0.provider == .codex && !self.codex.isEmpty && $0.email.caseInsensitiveCompare(self.codex) == .orderedSame }?.id
                let object: [String: Any] = ["accountID": claudeID ?? NSNull(), "email": claudeID == nil ? self.claude : "",
                                             "codexAccountID": codexID ?? NSNull(), "codexEmail": self.codex]
                return try JSONSerialization.data(withJSONObject: object)
            case "adopt":
                if self.adoptFails { throw BridgeFailure(message: "No Claude login was found on this Mac.") }
                self.adopted.append(args[1])
                return Data(#"{"email":""}"#.utf8)
            default: throw BridgeFailure(message: "not in this test")
            }
        }
    }
    func tick() async throws {
        #expect(await store.refreshActive())
        for _ in 0..<10 { await Task.yield() }
        await eventually { store.adopting.isEmpty }
    }
}

@MainActor @Test func aNewMacLoginIsAddedWithoutAClick() async throws {
    let mac = MacLogins()
    mac.claude = "New@Example.com"; mac.codex = "codex@example.com"
    try await mac.tick()
    let accounts = mac.store.config.accounts
    #expect(accounts.count == 2 && accounts.allSatisfy(\.ready))
    let claude = try #require(accounts.first { $0.provider == .claude })
    #expect(claude.email == "New@Example.com" && claude.name == "New" && claude.allowAuto)
    #expect(mac.store.activeIDs[.claude] == claude.id && mac.store.activeIDs[.codex] == accounts.first { $0.provider == .codex }?.id)
    #expect(mac.store.loginsToAdd.isEmpty)
    #expect(Set(WireBuilders.accounts(mac.store).map(\.email)) == ["New@Example.com", "codex@example.com"])
}

@MainActor @Test func aMacLoginIsAddedOnce() async throws {
    let mac = MacLogins()
    mac.claude = "dup@example.com"
    async let first = mac.store.refreshActive()
    async let second = mac.store.refreshActive()
    _ = await (first, second)
    try await mac.tick()
    try await mac.tick()
    #expect(mac.store.config.accounts.count == 1 && mac.adopted.count == 1)
    mac.claude = "DUP@example.com"
    try await mac.tick()
    #expect(mac.store.config.accounts.count == 1 && mac.adopted.count == 1)
}

@MainActor @Test func aRemovedLoginIsNotAddedBack() async throws {
    let mac = MacLogins()
    mac.claude = "gone@example.com"
    try await mac.tick()
    let id = try #require(mac.store.config.accounts.first?.id)
    mac.store.activeIDs = [:]
    mac.store.remove(id)
    #expect(mac.store.config.accounts.isEmpty && mac.store.config.wasRemoved("GONE@example.com", .claude))
    try await mac.tick()
    #expect(mac.store.config.accounts.isEmpty && mac.adopted.count == 1)
    #expect(mac.store.loginsToAdd[.claude] == "gone@example.com")
    mac.codex = "gone@example.com"
    try await mac.tick()
    #expect(mac.store.config.accounts.map(\.provider) == [.codex])

    #expect(await mac.store.adoptMacLogin(.claude))
    #expect(!mac.store.config.wasRemoved("gone@example.com", .claude) && mac.store.loginsToAdd.isEmpty)
    #expect(mac.store.config.accounts.count == 2)
}

@MainActor @Test func aFailedAddLeavesTheButton() async throws {
    let mac = MacLogins()
    mac.adoptFails = true
    mac.claude = "flaky@example.com"
    try await mac.tick()
    #expect(mac.store.config.accounts.isEmpty && mac.store.error == nil)
    #expect(mac.store.loginsToAdd[.claude] == "flaky@example.com")
    mac.adoptFails = false
    try await mac.tick()
    #expect(mac.store.config.accounts.isEmpty)
    #expect(await mac.store.adoptMacLogin(.claude))
    #expect(mac.store.config.accounts.count == 1 && mac.store.loginsToAdd.isEmpty)
}

@MainActor @Test func anAccountAddedWithoutANameTakesItsEmails() async throws {
    let store = AccountStore(demo: true)
    store.config.accounts = []
    let blank = try #require(store.addAccount(name: " ", email: ""))
    #expect(store.config.accounts.first { $0.id == blank }?.name == "Claude")
    #expect(await store.verify(blank))
    #expect(store.config.accounts.first { $0.id == blank }?.name == "you")
    let prefilled = try #require(store.addAccount(name: "", email: "pat@example.com", provider: .codex))
    #expect(store.config.accounts.first { $0.id == prefilled }?.name == "pat")
    let renamed = try #require(store.addAccount(name: "", email: ""))
    #expect(store.rename(renamed, "Studio"))
    #expect(await store.verify(renamed))
    #expect(store.config.accounts.first { $0.id == renamed }?.name == "Studio")
    let named = try #require(store.addAccount(name: "Work", email: ""))
    #expect(await store.verify(named))
    #expect(store.config.accounts.first { $0.id == named }?.name == "Work")
}

@MainActor @Test func aRemovedAccountLeavesThePhone() async throws {
    let store = AccountStore(demo: true)
    let queue = DispatchQueue(label: "test.hub")
    let hub = EventHub(queue: queue, epoch: "e1", snapshot: { { seq, epoch in StateSnapshot(seq: seq, epoch: epoch) } }, hello: {
        Hello(app: "", build: 0, mac: MacInfo(id: "", name: ""), capabilities: [], epoch: "e1", serverTime: 0, endpoints: Endpoints(tailnet: ""), keyID: "")
    })
    let events = RemoteEvents(store: store, hub: hub, queue: queue)
    events.start()
    defer { events.stop() }
    let id = store.config.accounts[1].id
    store.remove(id)
    events.usageChanged()
    func removal() -> Bool { hub.recorded(after: 0).contains { if case .accountRemove(id) = $0 { true } else { false } } }
    for _ in 0..<50 where !removal() { try await Task.sleep(for: .milliseconds(50)) }
    #expect(removal())
    #expect(!hub.recorded(after: 0).contains { if case .usageUpdate(let accounts) = $0 { accounts.contains { $0.id == id } } else { false } })
}

@MainActor @Test func anUnreadyAccountHoldingTheMacLoginIsConfirmed() async throws {
    let mac = MacLogins()
    mac.store.config.accounts = [Account(name: "Work", email: "work@example.com")]
    mac.claude = "work@example.com"
    try await mac.tick()
    #expect(mac.store.config.accounts.count == 1 && mac.store.config.accounts[0].ready && mac.adopted.isEmpty)
}
