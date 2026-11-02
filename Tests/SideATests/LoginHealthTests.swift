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
    let store = store { _ in throw BridgeFailure(message: "Side A: Sign in to A again; its login ended.") }
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
