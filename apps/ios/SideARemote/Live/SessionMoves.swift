import Foundation
import Observation
import SideAProtocol

/// One host's moves (`GET /v1/moves`) and the computers it can send a session to. Read, never pushed: when its session list
/// changes, when the app comes to the front, and every few seconds while a move is under way.
@Observable
final class SessionMoves {
    nonisolated deinit {}

    private(set) var records: [MoveRecord] = []
    private(set) var computers: [RemoteComputer]?

    @ObservationIgnored var following: Task<Void, Never>?
    @ObservationIgnored var seenSessions: Set<SessionKey> = []
    @ObservationIgnored var seenLive = false
    @ObservationIgnored var demo: DemoMoves?
    /// Conversations whose move waits for a turn that has ended: the host is about to send them.
    @ObservationIgnored var rested: Set<String> = []

    /// A move the host is still carrying out, or is about to.
    var inFlight: Bool { records.contains { $0.state == .moving || ($0.state == .waiting && rested.contains($0.conversationID)) } }

    func record(_ id: String) -> MoveRecord? { records.first { $0.id == id } }

    func record(conversation: String) -> MoveRecord? { records.first { $0.conversationID == conversation } }

    func set(_ records: [MoveRecord]) { if self.records != records { self.records = records } }

    func set(computers: [RemoteComputer]) { if self.computers != computers { self.computers = computers } }

    /// Newest first, as the host lists them.
    func update(_ record: MoveRecord) {
        var next = records.filter { $0.id != record.id }
        next.insert(record, at: 0)
        set(next)
    }

    /// The conversation is back on this host, so nothing here says it is away.
    func forget(conversation: String) { set(records.filter { $0.conversationID != conversation }) }

    /// The rows the session list shows for sessions that left: sent, being sent, or lost track of. One this host lists again
    /// is back, and its own row says so.
    func shown(listed: [RemoteSession]) -> [MoveRecord] {
        let here = Set(listed.compactMap(\.conversationID))
        return records.filter { record in
            [.moving, .away, .unknown].contains(record.state) && (record.state == .moving || !here.contains(record.conversationID))
        }
    }

    /// Stopped and on its way: its row gives way to the move's.
    func isLeaving(_ session: RemoteSession) -> Bool {
        guard let conversation = session.conversationID else { return false }
        return records.contains { $0.conversationID == conversation && $0.state == .moving }
    }
}

extension MoveRecord {
    func with(state: State, session: String? = nil, message: String? = nil) -> MoveRecord {
        MoveRecord(id: id, conversationID: conversationID, agent: agent, title: title, project: project, state: state, computer: computer,
                   computerName: computerName, at: at, session: session ?? self.session, message: message ?? self.message)
    }
}

enum MoveText {
    static func status(_ record: MoveRecord) -> String {
        switch record.state {
        case .moving: "Moving to \(record.computerName)…"
        case .waiting: "Moves to \(record.computerName) after this turn"
        case .away: "On \(record.computerName)"
        case .unknown: "May be running on \(record.computerName)"
        default: record.message ?? "It didn't move."
        }
    }

    /// What happens to the account, when anything does: the login goes with it, or it runs on one the other computer has.
    static func account(_ preview: MovePreview) -> String? {
        switch preview.login {
        case .sent?: preview.account.map { "Signs \(preview.computer.name) in to \($0)" }
        case .other?: "Runs on \(preview.computer.name)'s own account"
        default: nil
        }
    }

    static func title(_ record: MoveRecord) -> String { record.title ?? record.project ?? "Session" }

    /// The other computer's home as `~`, so the part of the path that differs is what shows.
    static func folder(_ path: String) -> String {
        for home in ["/Users/", "/home/"] where path.hasPrefix(home) {
            let rest = path.dropFirst(home.count)
            return rest.firstIndex(of: "/").map { "~" + rest[$0...] } ?? "~"
        }
        return path
    }
}

enum MoveLanding {
    /// The other computer's row for a moved conversation: the hosted session the move named, else the same conversation.
    static func session(for record: MoveRecord, in rows: [RemoteSession]) -> RemoteSession? {
        record.session.flatMap { name in rows.first { $0.hosted == name } } ?? rows.first { $0.conversationID == record.conversationID }
    }
}

extension RemoteComputer {
    var symbol: String {
        switch os ?? .macos {
        case .macos: "desktopcomputer"
        case .windows, .wsl: "pc"
        default: "server.rack"
        }
    }
}
