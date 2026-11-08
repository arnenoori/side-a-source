import Foundation
@testable import SideA
import SideACore
import Testing
import UserNotifications

private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))") }

@MainActor private func store(_ bridge: @escaping @Sendable ([String]) async throws -> Data) -> AccountStore {
    let store = AccountStore(demo: true, root: temporaryRoot())
    store.config.accounts = [Account(name: "A", email: "a@example.com", ready: true, allowAuto: true)]
    store.testBridge = bridge
    return store
}

@MainActor @Test func aFailedReadOfTheLoginsInUseKeepsItsReason() async {
    let store = store { _ in throw BridgeFailure(message: "Side A: The Keychain didn't answer (exit 36); retrying later.") }
    #expect(await store.refreshActive() == false)
    #expect(store.activeProblem?.contains("exit 36") == true)
}

@MainActor @Test func anAnswerThatCantBeReadSaysSo() async {
    let store = store { _ in Data("not json".utf8) }
    #expect(await store.refreshActive() == false)
    #expect(store.activeProblem == "its answer couldn't be read")
}

@MainActor @Test func theReasonSessionsCouldntBeListedComesFromTheBridge() async {
    let answer = #"{"busyProblem":"process 41 (S+) unreadable: Invalid argument","accountID":null,"email":"","codexAccountID":null,"codexEmail":"","busy":null}"#
    let store = store { _ in Data(answer.utf8) }
    #expect(await store.refreshActive())
    #expect(store.activeProblem == nil)
    #expect(store.busyLogins == nil)
    #expect(store.busyProblem == "process 41 (S+) unreadable: Invalid argument")
}

@MainActor @Test func aRefusedRenewalIsNotASignOut() async {
    let store = store { _ in throw BridgeFailure(message: "Side A: Renewing the login was refused (HTTP 403, none); retrying later.") }
    let id = store.config.accounts[0].id
    await store.renew(id)
    #expect(store.health[id]?.takesWork != false)
    #expect(store.signInWarned.isEmpty)
}

@MainActor @Test func anEndedLoginIsASignOutAndWarnsOnce() async {
    let store = store { _ in throw BridgeFailure(stderr: "Side A[signin]: Sign in to A again; its login ended.") }
    let id = store.config.accounts[0].id
    await store.renew(id)
    #expect(store.health[id]?.takesWork == false)
    #expect(store.signInWarned == [id])
}

@MainActor @Test func aKeychainThatDoesntAnswerIsNotASignOut() async {
    let store = store { _ in throw BridgeFailure(message: "Side A: The Keychain didn't answer (exit 36); retrying later.") }
    let id = store.config.accounts[0].id
    await store.renew(id)
    #expect(store.health[id]?.takesWork != false)
}

@Test func theSignInButtonAndAClickNameTheAccount() {
    let info: [AnyHashable: Any] = [NotificationRouter.signInKey: "acct"]
    #expect(NotificationRouter.signInTarget(info: info, action: NotificationRouter.signInAction) == "acct")
    #expect(NotificationRouter.signInTarget(info: info, action: UNNotificationDefaultActionIdentifier) == "acct")
    #expect(NotificationRouter.signInTarget(info: info, action: UNNotificationDismissActionIdentifier) == nil)
    #expect(NotificationRouter.signInTarget(info: ["session": "s"], action: UNNotificationDefaultActionIdentifier) == nil)
    #expect(NotificationRouter.signInTarget(info: [NotificationRouter.signInKey: ""], action: NotificationRouter.signInAction) == nil)
}

@MainActor private func named(_ name: String, _ bridge: @escaping @Sendable ([String]) async throws -> Data) -> (AccountStore, String) {
    let store = store(bridge)
    store.config.accounts[0].name = name
    return (store, store.config.accounts[0].id)
}

@Test func theBridgesCodeDecidesAndIsTakenOutOfTheMessage() {
    let signIn = BridgeFailure(stderr: "Side A[signin]: Sign in to bridle again.")
    #expect(signIn.kind == .signIn && signIn.message == "Side A: Sign in to bridle again.")
    #expect(BridgeFailure(stderr: "warning: x\nSide A[rate-limited]: Codex usage is rate-limited (429).").kind == .rateLimited)
    let unknown = BridgeFailure(stderr: "Side A[newer]: Something new.")
    #expect(unknown.kind == .other && unknown.message == "Side A: Something new.")
    #expect(BridgeFailure(stderr: "Side A: Sign in to idle 429 again.").kind == .other)
    #expect(BridgeErrorKind(CocoaError(.fileNoSuchFile)) == .other)
}

/// "bridle" holds "idle": its ended login must read as signed out, not idle and renewed forever.
@MainActor @Test func anAccountNamedLikeIdleIsStillSignedOut() async {
    let (store, id) = named("bridle") { _ in throw BridgeFailure(stderr: "Side A[signin]: Sign in to bridle again.") }
    await store.refreshUsage(id)
    #expect(store.health[id] == .signIn())
    #expect(store.signInWarned == [id])
}

@MainActor @Test func anAccountNamedLike429IsStillSignedOut() async {
    let (store, id) = named("dev429") { _ in throw BridgeFailure(stderr: "Side A[signin]: Sign in to dev429 again.") }
    await store.refreshUsage(id)
    #expect(store.health[id] == .signIn())
}

@MainActor @Test func anUncodedFailureNamingIdleOr429IsOffline() async {
    let (store, id) = named("idle 429 Sign in") { _ in throw BridgeFailure(stderr: "Side A: idle 429 Sign in couldn't be read.") }
    await store.refreshUsage(id)
    #expect(store.health[id] == .offline)
    #expect(store.signInWarned.isEmpty)
}

@MainActor @Test func theCodesForIdleRateLimitAndUnconfirmedKeepTheirMeaning() async {
    let (idle, idleID) = named("A") { args in
        if args.first == "renew" { throw BridgeFailure(stderr: "Side A: Renewing the login failed (HTTP 500); retrying later.") }
        throw BridgeFailure(stderr: "Side A[idle]: Login idle; its last reading still applies.")
    }
    await idle.refreshUsage(idleID)
    #expect(idle.health[idleID] == .idle)
    let (limited, limitedID) = named("A") { _ in throw BridgeFailure(stderr: "Side A[rate-limited]: Usage is unavailable right now (HTTP 429).") }
    limited.health[limitedID] = .offline
    await limited.refreshUsage(limitedID)
    #expect(limited.health[limitedID] == nil)
    let (unconfirmed, unconfirmedID) = named("A") { _ in throw BridgeFailure(stderr: "Side A[unconfirmed]: Can't confirm whose login this is yet; retrying later.") }
    await unconfirmed.refreshUsage(unconfirmedID)
    #expect(unconfirmed.health[unconfirmedID] == .verify)
}

@MainActor private func testingPool(_ name: String, _ bridge: @escaping @Sendable ([String]) async throws -> Data) async -> (AccountStore, String) {
    let (store, id) = named(name, bridge)
    let pool = PoolProxy(key: String(repeating: "a", count: 64), decisions: store)
    store.poolRun = .running(pool, port: 0)
    await store.testPool()
    pool.stop()
    return (store, id)
}

/// Test Pool once showed a revoked "dev429" as Ready, because its message held "429".
@MainActor @Test func testPoolDoesntCallARevokedLoginNamedLike429Ready() async {
    let (store, id) = await testingPool("dev429") { _ in throw BridgeFailure(stderr: "Side A[signin]: Sign in to dev429 again.") }
    #expect(store.poolTest?[id] == "Sign in to dev429 again.")
    #expect(store.health[id] == .signIn())
}

@MainActor @Test func testPoolCallsARateLimitedOrIdleReadReady() async {
    for code in ["rate-limited", "idle"] {
        let (store, id) = await testingPool("A") { args in
            if args.first == "pool-token" { return Data(#"{"accessToken":"t","accountId":null,"expiresAt":4102444800000,"hash":"h"}"#.utf8) }
            throw BridgeFailure(stderr: "Side A[\(code)]: No reading now.")
        }
        #expect(store.poolTest?[id] == "Ready")
    }
}
