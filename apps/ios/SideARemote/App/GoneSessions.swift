import SideAProtocol

enum GoneSessions {
    /// Where a path is cut because the session its page shows was quit: that session's page and any step, diff or file
    /// pushed over it, whichever page is on top.
    static func firstEnded(in path: [Route], ended: (_ session: SessionKey, _ mac: String) -> Bool) -> Int? {
        var mac = ""
        for (index, route) in path.enumerated() {
            if case .session(let id, let owner) = route {
                mac = owner
                if ended(id, owner) { return index }
            } else if let id = route.session, ended(id, mac) {
                return index
            }
        }
        return nil
    }
}
