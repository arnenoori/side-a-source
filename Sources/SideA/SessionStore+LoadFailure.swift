/// A conversation that couldn't be opened, kept with the session it was for. `SessionStore.error` is for actions (quit, resume,
/// open a terminal), which fail without saying anything about the conversation on screen.
struct LoadFailure: Equatable {
    let id: String
    let message: String
}

extension SessionStore {
    /// The message for the selected conversation, never one for another session or for an action.
    var loadFailure: String? {
        guard let loadError, loadError.id == selectedID else { return nil }
        return loadError.message
    }
}
