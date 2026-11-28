import Foundation
import SideACore
import SideAProtocol

extension SessionStore {
    /// Edit from Here is offered on what the user said in a Claude conversation: Codex has no way to resume part of one.
    func canRewind(_ session: SessionInfo, _ message: SessionMessage) -> Bool { !store.isDemo && Self.rewinds(session, message) }

    static func rewinds(_ session: SessionInfo, _ message: SessionMessage) -> Bool {
        message.role == "user" && !session.isCodex && session.cwd != nil && !message.uuid.isEmpty
    }

    /// Starts a copy of the conversation that ends just before `message`, with the message's words ready to change
    /// and send. The conversation itself is left as it is.
    func rewind(_ session: SessionInfo, at message: SessionMessage) {
        guard canRewind(session, message), let cwd = session.cwd else { return }
        guard FileManager.default.fileExists(atPath: cwd) else {
            error = "Its folder no longer exists (\(cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))), so it can't be continued there."
            return
        }
        Task {
            do {
                struct Cut: Decodable { let id: String }
                let cut = try JSONDecoder().decode(Cut.self, from: try await remoteReply(["cut", "--before", message.uuid, "--", session.id]))
                begin(cut.id, in: cwd, saying: message.text)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func begin(_ conversation: String, in cwd: String, saying text: String) {
        guard store.hostingWanted, store.hosted.available else {
            drafts[conversation] = text
            let bare = "claude --resume \(conversation)"
            return open("cd \(Shell.quote(cwd)) && \(bare)", bare: bare, cwd: cwd, in: resumeTerminal, file: "rewind-\(conversation.prefix(8))")
        }
        launch(StartHosted(cwd: cwd, agent: .claude, resume: conversation), terminal: desk.prefs.start.terminal)
        // The launch's own composer holds the words until the session is listed, when they become its draft.
        if let made = desk.launches.first, made.request.resume == conversation { desk.held[made.id] = text }
    }
}
