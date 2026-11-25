import Foundation
import SideAProtocol

extension SessionsStore {
    /// A launch the Mac never reports as running ends here, so a session that never took its prompt settles into Idle.
    static let launchGrace: TimeInterval = 120

    func launch(_ name: String, at: Date = .now) { launching[name] = at }

    func endLaunch(_ name: String) { launching[name] = nil }

    /// A launching hosted row the Mac still calls idle is starting: it is the same row from the tap, through
    /// the prompt landing, to its first turn, and only a turn (or the grace running out) hands it back to the Mac's word.
    func launched(_ rows: [RemoteSession], now: Date) -> [RemoteSession] {
        guard !launching.isEmpty else { return rows }
        return rows.map { row in
            guard let name = row.hosted, let since = launching[name] else { return row }
            guard row.status == .idle || row.status == .starting, now.timeIntervalSince(since) < Self.launchGrace else {
                launching[name] = nil
                return row
            }
            var row = row
            row.status = .starting
            return row
        }
    }

    /// The row a booting hosted session has before the Mac lists it. Its `tmux-<name>` id is the one the wire documents
    /// for that moment; `rowID` is what keeps it and the real row one list identity.
    static func placeholder(_ hosted: HostedSession, prompt: String?) -> RemoteSession {
        RemoteSession(id: "tmux-\(hosted.name)", agent: hosted.agent, title: prompt ?? hosted.project, cwd: hosted.cwd, project: hosted.project,
                      status: .starting, statusAt: hosted.createdAt, hosted: hosted.name)
    }
}

extension RemoteSession {
    /// One identity for a hosted session from its placeholder on, whatever id the Mac gives it later.
    var rowID: String { hosted ?? id }
}

extension AppModel {
    /// Hosted sessions alive on the Mac with no row yet, as placeholder rows for the Working group.
    var bootingRows: [RemoteSession] {
        tools.unlisted(in: sessions.sessions).map { SessionsStore.placeholder($0, prompt: transcripts.firstPrompts[$0.name]?.text) }
    }
}
