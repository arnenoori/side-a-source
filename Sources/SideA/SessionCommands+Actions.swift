import Foundation
import SideACore
import SideAProtocol

/// Quitting, stopping a server, starting a hosted session and Restart Fresh, for the phone and the Sessions window.
extension SessionCommands {
    nonisolated static func internalFailure(_ message: String) -> Failure { Failure(status: 500, code: "internal", message: message) }

    // MARK: Quit

    /// Any interactive session: hosted ones end with their tmux session, others get SIGTERM (Claude Code saves on it).
    func quit(_ id: String) async throws(Failure) {
        guard let live = Target(id, store: store)?.live else { throw .noSession }
        if let kind = live.kind, kind != "interactive" {
            throw Failure(status: 409, code: "cannot_deliver", message: "That's an automated run, so Side A doesn't quit it.")
        }
        guard let fresh = await store.sessions.freshLive() else {
            throw Failure(status: 503, code: "not_ready", message: "Side A couldn't check whether that session is still running.", retryAfter: 2)
        }
        guard let now = SessionStore.current([live], in: fresh, still: { $0.kind.map { $0 == "interactive" } ?? true }).first else { throw .noSession }
        if let name = now.hosted, store.hosted.sessions.contains(where: { $0.name == name }) {
            do { try await store.hosted.end(name) } catch { throw .hosted(error as? HostedError ?? .failed("Side A couldn't end that session.")) }
            return
        }
        guard !store.sessions.signal([now]).isEmpty else { throw .noSession }
        refreshSoon()
    }

    /// Idle sessions untouched for at least the given minutes, checked again against a fresh list before each goes.
    func quitIdle(olderThanMinutes minutes: Int) async throws(Failure) -> [SessionKey] {
        let cutoff = Date().timeIntervalSince1970 - Double(minutes) * 60
        let quiet = { (session: LiveSession) in
            session.status == "idle" && (session.since ?? .infinity) <= cutoff && (session.kind.map { $0 == "interactive" } ?? true)
        }
        guard let fresh = await store.sessions.freshLive() else {
            throw Failure(status: 503, code: "not_ready", message: "Side A couldn't check which sessions are still running.", retryAfter: 2)
        }
        let candidates = SessionStore.current(store.sessions.live.filter(quiet), in: fresh, still: quiet)
        var quit: [SessionKey] = []
        for session in candidates {
            guard let name = session.hosted, store.hosted.sessions.contains(where: { $0.name == name }) else { continue }
            if (try? await store.hosted.end(name)) != nil { quit.append(WireBuilders.key(session)) }
        }
        quit += store.sessions.signal(candidates.filter { $0.hosted == nil }).map(WireBuilders.key)
        if !quit.isEmpty { refreshSoon() }
        return quit
    }

    /// A server the session started, when a fresh list still shows that same process listening there.
    func stopServer(_ id: String, port number: Int?) async throws(Failure) {
        guard let live = Target(id, store: store)?.live else { throw .noSession }
        guard let port = live.ports?.first(where: { $0.port == number }), await store.sessions.endServer(port) else {
            throw Failure(status: 404, code: "port_not_found", message: "That server isn't running any more.")
        }
        refreshSoon()
    }

    private func refreshSoon() {
        let sessions = store.sessions
        Task { try? await Task.sleep(for: .seconds(1)); await sessions.refreshLive() }
    }

    // MARK: Start

    /// A new, resumed or forked session in Side A's tmux. `origin` names who asked, for the session's record.
    func start(_ start: StartHosted, images: [String] = [], key: String? = nil, origin: String) async throws(Failure) -> String {
        let agent: Hosting.Agent = start.agent == .codex ? .codex : .claude
        let mode: Hosting.Mode = start.resume.map { start.fork ? .fork($0) : .resume($0) } ?? .new(model: start.model)
        let account = start.accountID.flatMap { id in store.config.accounts.first { $0.id == id && $0.provider == start.agent } }
        if start.accountID != nil, account == nil { throw Failure(status: 404, code: "not_found", message: "That account isn't on the Mac.") }
        guard Hosting.safeOption(start.model), Hosting.safeOption(start.effort) else { throw .invalid("That model or effort isn't one Side A can start.", "invalid_option") }
        var request = HostedSessions.Start(agent: agent, cwd: start.cwd, mode: mode)
        request.origin = origin
        request.prompt = start.prompt
        request.images = images
        request.key = key
        request.worktree = start.worktree ? "HEAD" : nil
        request.effort = start.effort == Effort.auto.rawValue ? nil : start.effort
        request.permissionMode = start.permissionMode?.rawValue
        if let account {
            if agent == .claude { request.pin = RemoteProjects.pin(account.name) } else { request.codexAccount = account.id }
        }
        do {
            return try await store.hosted.start(request)
        } catch HostedError.alreadyLive(let running) {
            var details = ["hint": "alreadyLive", "sessionID": WireBuilders.key(running)]
            if let hosted = running.hosted { details["hosted"] = hosted }
            throw Failure(status: 409, code: "cannot_deliver", message: "That session is already running.", details: details)
        } catch let error as HostedError {
            throw .hosted(error)
        } catch {
            throw Self.internalFailure("Side A couldn't start that session.")
        }
    }

    /// A Claude conversation that is running, forked into a new hosted session in its folder.
    func fork(_ id: String, origin: String) async throws(Failure) -> String {
        guard let live = Target(id, store: store)?.live, let conversation = live.sessionID, let cwd = live.cwd else { throw .noSession }
        return try await start(StartHosted(cwd: cwd, agent: live.provider, accountID: store.sessions.accountID(of: live), resume: conversation, fork: true),
                               origin: origin)
    }

    // MARK: Restart Fresh

    /// A draft only: the conversation's first prompt as the goal, its health flag as what failed, its branch and its
    /// last few turns, to edit and hand to `restart`.
    func handoff(_ id: String) async throws(Failure) -> Handoff {
        guard let live = Target(id, store: store)?.live, let conversation = live.sessionID, IDs.safe(conversation), let cwd = live.cwd else {
            throw .noSession
        }
        let accountID = store.sessions.accountID(of: live)
        struct Listing: Decodable { let sessions: [SessionInfo] }
        let info: SessionInfo?
        let page: TranscriptPage
        do {
            info = try SessionBridge.decode(try await store.sessions.remoteReply(["recent", "--only", conversation]), as: Listing.self).sessions.first
            page = try RemoteTranscript.page(try await store.sessions.remoteReply(["show", "--format", "remote", "--limit", "40", "--", conversation]))
        } catch { throw Self.readFailure(error) }
        let branch = await Task.detached { RemoteProjects.git(cwd).branch }.value ?? info?.branch
        let goal = String((info?.firstPrompt ?? info?.title ?? live.title ?? "").prefix(2000))
        return Handoff(goal: goal, branch: branch, failed: live.flag?.text ?? "", next: "",
                       lastMessages: Self.lastMessages(page.messages, agent: live.provider), cwd: cwd,
                       project: URL(fileURLWithPath: cwd).lastPathComponent, accountID: accountID, model: info?.model)
    }

    /// Starts the new hosted session first and ends the old one only once it's up, so a failed start loses nothing.
    func restart(_ id: String, _ body: RestartRequest, key: String? = nil, origin: String) async throws(Failure) -> String {
        let prompt = Self.prompt(body.handoff)
        guard prompt.count <= Self.maxReply else { throw .invalid("That handoff is too long.", "too_long") }
        guard store.hosted.available else { throw .hosted(.unavailable) }
        guard let live = Target(id, store: store)?.live, let cwd = live.cwd else { throw .noSession }
        if let kind = live.kind, kind != "interactive" {
            throw Failure(status: 409, code: "cannot_deliver", message: "That's an automated run, so it can't be restarted.")
        }
        guard body.handoff.cwd == cwd else { throw Failure(status: 409, code: "cannot_deliver", message: "That handoff is for another folder.") }
        let name = try await start(StartHosted(cwd: cwd, agent: live.provider, model: body.model ?? body.handoff.model,
                                               accountID: body.accountID ?? body.handoff.accountID, prompt: prompt), key: key, origin: origin)
        if let old = live.hosted, store.hosted.sessions.contains(where: { $0.name == old }) {
            try? await store.hosted.end(old)
        } else {
            _ = await store.sessions.terminate([live], still: { _ in true })
        }
        return name
    }

    /// The last six turns with text, as markdown, each cut to 1,500 characters.
    nonisolated static func lastMessages(_ messages: [TranscriptMessage], agent: AgentProvider) -> String {
        let name = agent == .codex ? "Codex" : "Claude"
        return messages.filter { ($0.role == .user || $0.role == .assistant) && !($0.text ?? "").isEmpty }.suffix(6).map { message in
            let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return "**\(message.role == .user ? "You" : name):** " + (text.count > 1500 ? text.prefix(1500) + "…" : text)
        }.joined(separator: "\n\n")
    }

    /// The first prompt the new session gets; empty parts are left out.
    nonisolated static func prompt(_ handoff: Handoff) -> String {
        let parts = [("Goal", handoff.goal), ("Branch", handoff.branch.map { "`\($0)`" } ?? ""), ("What failed", handoff.failed),
                     ("Next steps", handoff.next), ("Last messages", handoff.lastMessages)]
        return (["This continues an earlier session that was restarted fresh. Its handoff:"]
                + parts.compactMap { title, text in
                    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : "## \(title)\n\n\(text)"
                }).joined(separator: "\n\n")
    }

    /// A bridge read that failed, as the phone hears it.
    nonisolated static func readFailure(_ error: Error) -> Failure {
        switch error {
        case let failure as RemoteTranscript.Failure where failure.missing: .noSession
        case let failure as RemoteTranscript.Failure where failure.badCursor:
            Failure(status: 400, code: "bad_request", message: "That cursor isn't one this Mac gave out.")
        case is BridgeFailure: Failure(status: 503, code: "not_ready", message: "Side A is still starting its session reader.", retryAfter: 2)
        default: internalFailure("Side A couldn't read that session.")
        }
    }
}
