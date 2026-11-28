import Foundation
import SideAProtocol

/// `--demo --demo-macs 2`: the Mac mini keeps a checkpoint of the MacBook Pro's LAN mode session. Continuing it starts a
/// copy on the Mac mini, a fork with its own conversation, and leaves the MacBook Pro's session as it was.
final class DemoStandby {
    nonisolated deinit {}

    private weak var root: AppRoot?
    private let macID: String
    /// How long the copy takes to start, so the row shows it under way.
    var delay: Duration = .seconds(1.5)
    /// Each checkpoint's copy, so continuing one again answers with the session already running, as the host does.
    private var made: [String: MoveState] = [:]

    private init(root: AppRoot, macID: String) { self.root = root; self.macID = macID }

    static func link(_ root: AppRoot) {
        guard root.macs.count > 1, let book = root.macs.first, let mini = root.macs.last,
              let session = book.sessions.session(DemoData.ID.lan), let conversation = session.conversationID else { return }
        mini.tools.standby.demo = DemoStandby(root: root, macID: mini.macID)
        mini.tools.standby.set([StandbyCopy(conversationID: conversation, agent: session.agent, title: book.tools.title(for: session),
                                            project: session.project, computer: book.macID, computerName: book.mac.name,
                                            at: Date.now.timeIntervalSince1970 - 6 * 60)])
    }

    private var here: AppModel? { root?.model(for: macID) }

    func continueCopy(_ conversation: String) async throws -> MoveState {
        guard let here, let copy = here.tools.standby.copy(conversation) else { throw ToolError.gone }
        if let state = made[conversation], here.sessions.sessions.contains(where: { $0.hosted == state.session }) { return state }
        try? await Task.sleep(for: delay)
        let project = copy.project ?? "session"
        let name = "sa-\(project)-\(UUID().uuidString.prefix(4).lowercased())"
        let folder = "/Users/you/Side A Sessions/\(project)/.sidea-worktrees/\(name)"
        let fork = UUID().uuidString.lowercased()
        let now = Date.now.timeIntervalSince1970
        let started = RemoteSession(id: fork, conversationID: fork, agent: copy.agent, title: StandbyText.title(copy), cwd: folder, project: project,
                                    status: .idle, statusAt: now, hosted: name, abilities: [.transcript, .type, .interrupt, .terminal, .end])
        here.sessions.replace(here.sessions.sessions + [started], finished: [:])
        if let source = root?.model(for: copy.computer), let original = source.sessions.sessions.first(where: { $0.conversationID == conversation }),
           let messages = source.transcripts.messages[original.id] {
            here.transcripts.set(messages, hasEarlier: false, for: fork)
        }
        let state = MoveState(id: "sb-demo-\(fork.prefix(8))", status: .live, session: name, folder: folder)
        made[conversation] = state
        return state
    }
}
