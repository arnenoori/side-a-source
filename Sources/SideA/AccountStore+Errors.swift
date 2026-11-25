import Foundation

/// What a shown `AccountStore.error` is about, so the same thing succeeding later takes it down. An error set
/// without a subject (a settings file that couldn't be read, say) stays until it is dismissed.
enum ErrorSubject: Equatable {
    case account(String)
    case pool
}

extension AccountStore {
    func report(_ message: String, for subject: ErrorSubject) {
        error = message
        errorSubject = subject
    }

    /// The thing the error described worked, so the error is stale. Another subject's error is left alone.
    func resolve(_ subject: ErrorSubject) {
        guard error != nil, errorSubject == subject else { return }
        error = nil
    }

    /// A login that changed (signed in again, or refreshed by Claude Code) is a new login: its health and the "sign in
    /// again" mark on the last reading belonged to the old one, so the row and the planner stop holding it against the account.
    func forgetOldLoginHealth(_ id: String) {
        health[id] = nil
        usage[id]?.stale = false
    }
}
