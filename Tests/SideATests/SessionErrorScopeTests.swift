import Foundation
@testable import SideA
import Testing

@MainActor private func sessions() -> SessionStore {
    SessionStore(store: AccountStore(demo: true, root: FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))")))
}

@MainActor @Test func anActionErrorIsNotACantOpenThisConversation() {
    let model = sessions()
    model.error = "Terminal could not be opened: no."
    #expect(model.loadFailure == nil)
    model.selectedID = "a"
    #expect(model.loadFailure == nil)
}

@MainActor @Test func aFailedLoadBelongsToTheConversationItWasFor() async {
    let model = sessions()
    model.open("a")
    // No reader on a test Mac: the load fails, and says so for "a" alone.
    #expect(await eventually { model.loadFailure != nil })
    #expect(model.error == nil)
    model.selectedID = "b"
    #expect(model.loadFailure == nil)
}
