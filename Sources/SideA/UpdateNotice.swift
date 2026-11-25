/// What the menu says about updates. One value, so it can't say "Updated to X" and "Update didn't install" together.
enum UpdateNotice: Equatable {
    case available(String, failed: Bool)
    case updated(String)
    case failed

    /// A failure only counts while there is something left to install: a Mac already on the version it just updated
    /// to (by hand, or after Sparkle's own retry) has nothing to download.
    init?(available: String?, updated: String?, failed: Bool) {
        if let available { self = .available(available, failed: failed) } else if let updated { self = .updated(updated) } else if failed { self = .failed } else { return nil }
    }
}

extension Updates {
    func notice() -> UpdateNotice? { UpdateNotice(available: available, updated: updated(), failed: failure != nil) }
}
