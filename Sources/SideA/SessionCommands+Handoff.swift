import Foundation
import SideACore
import SideAProtocol

extension SessionCommands {
    static func signedIn(_ store: AccountStore, _ agent: AgentProvider) -> Bool {
        store.activeIDs[agent] != nil || store.unknownLogins[agent]?.isEmpty == false || store.config.accounts.contains { $0.provider == agent }
    }

    /// Never the reason a handoff fails: a slow or broken git gives nil.
    nonisolated static func changes(_ cwd: String) async -> String? {
        func git(_ args: [String]) async -> String? {
            let run = await HostedSessions.process("/usr/bin/git", ["-C", cwd] + args, environment: ["GIT_OPTIONAL_LOCKS": "0"], timeout: 3)
            return run.status == 0 ? run.output.trimmingCharacters(in: .newlines) : nil
        }
        guard let status = await git(["status", "--short", "--untracked-files=normal"]) else { return nil }
        var base: String?
        for upstream in ["@{upstream}", "origin/HEAD", "main", "master"] {
            if let found = await git(["merge-base", "HEAD", upstream]), !found.isEmpty { base = found; break }
        }
        let stat = await git(["diff", "--stat=100", base ?? "HEAD"]) ?? ""
        let (shownStatus, hiddenStatus) = withoutSecrets(status) { String($0.dropFirst(3)).components(separatedBy: " -> ") }
        let (shownStat, hiddenStat) = withoutSecrets(stat) { [$0.components(separatedBy: " | ").first ?? ""] }
        let hidden = max(hiddenStatus, hiddenStat)
        let note = hidden == 0 ? "" : "\(hidden) \(hidden == 1 ? "file" : "files") with a name like a key or credential left out."
        let text = [shownStatus, shownStat, note].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return text.isEmpty ? nil : String(text.prefix(HandoffText.changesLimit * 2))
    }

    /// The same names a file mention refuses: an untracked `.env.local` is listed by git status, and the list reaches
    /// the phone and the new agent.
    nonisolated static func withoutSecrets(_ listing: String, paths: (String) -> [String]) -> (String, Int) {
        var hidden = 0
        let kept = listing.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let secret = paths(String(line)).contains { path in
                FileReads.secret(path.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).split(separator: "/").map(String.init))
            }
            if secret { hidden += 1 }
            return !secret
        }
        return (kept.joined(separator: "\n"), hidden)
    }

    func transcriptPath(_ conversation: String, agent: AgentProvider) async -> String? {
        let homes = RemoteOptions.homes(store)
        if agent == .claude { return RemoteRoutes.claudeTranscript(conversation, home: homes.home)?.path }
        let sessions = homes.codex.appendingPathComponent("sessions")
        return await Task.detached {
            let found = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil)?.lazy
                .compactMap { $0 as? URL }.first { $0.lastPathComponent.hasPrefix("rollout-") && $0.lastPathComponent.hasSuffix("\(conversation).jsonl") }
            return found?.path
        }.value
    }

    func addHandoffFacts(_ draft: inout Handoff, live: LiveSession) async {
        draft.plan = store.remote.codex.row(live)?.plan ?? live.plan
        draft.fromAgent = live.provider
        if let cwd = live.cwd { draft.changes = await Self.changes(cwd) }
        if let conversation = live.sessionID { draft.transcriptPath = await transcriptPath(conversation, agent: live.provider) }
    }

    nonisolated static func turns(_ messages: [TranscriptMessage]) -> [HandoffText.Turn] {
        messages.compactMap { message in
            guard message.role == .user || message.role == .assistant,
                  let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return HandoffText.Turn(user: message.role == .user, text: text)
        }
    }

    /// The old session ends only once the new one is up and has outlived its start, so a failed start loses nothing.
    func handOff(_ id: String, _ body: RestartRequest, to agent: AgentProvider, images: [String] = [], key: String?, origin: String) async throws(Failure) -> (String, HandoffLink) {
        let message = body.message ?? ""
        guard message.count <= Self.maxReply else { throw .invalid("Your message alone is longer than a reply can be. Shorten it first.", "too_long") }
        guard store.hosted.available else { throw .hosted(.unavailable) }
        guard let live = Target(id, store: store)?.live, let cwd = live.cwd, let conversation = live.sessionID, IDs.safe(conversation) else {
            throw .noSession
        }
        if let kind = live.kind, kind != "interactive" {
            throw Failure(status: 409, code: .cannotDeliver, message: "That's an automated run, so it can't be handed off.")
        }
        guard body.handoff.cwd == cwd else { throw Failure(status: 409, code: .cannotDeliver, message: "That handoff is for another folder.") }
        guard store.isInstalled(agent) else {
            throw Failure(status: 409, code: .cannotDeliver, message: "\(agent.cliName) isn't installed on this Mac.", details: ["agent": agent.rawValue])
        }
        guard Self.signedIn(store, agent) else {
            throw Failure(status: 409, code: .cannotDeliver, message: "\(agent.title) isn't signed in on this Mac.", details: ["agent": agent.rawValue])
        }
        // A question or dialog Side A's hooks never saw (Codex's, or an unhooked Claude's) shows only as waiting.
        if live.status == "waiting"
            || store.island.pending.contains(where: { ($0.request.sessionID != nil && $0.request.sessionID == conversation) || $0.request.pid == live.pid }) {
            throw Failure(status: 409, code: .cannotDeliver, message: "Answer or deny \(live.provider.title)'s open request first.")
        }
        var mode = body.permissionMode ?? .default
        var fellBack = false
        if Hosting.permissionArguments(agent == .codex ? .codex : .claude, mode: mode.rawValue) == nil { mode = .default; fellBack = true }

        let links = HandoffLinks.of(store)
        await links.loaded(store)
        let page: TranscriptPage
        do {
            page = try RemoteTranscript.page(try await store.sessions.remoteReply(["show", "--format", "remote", "--turns", "--", conversation]))
        } catch { throw Self.readFailure(error) }
        let turns = Self.turns(page.messages)
        let fromModel = live.model ?? body.handoff.model
        var parts = HandoffText.Parts(goal: body.handoff.goal, branch: body.handoff.branch, changes: body.handoff.changes, plan: body.handoff.plan,
                                      health: live.flag?.text ?? "", failed: body.handoff.failed, next: body.handoff.next,
                                      from: live.provider, fromModel: fromModel, to: agent)
        parts.transcript = await transcriptPath(conversation, agent: live.provider)
        let handoffID = UUID().uuidString.lowercased()
        parts.file = links.fullFile(handoffID).path
        var record = HandoffLinks.Record(id: handoffID, fromConversation: conversation, toConversation: nil, fromAgent: live.provider.rawValue,
                                         toAgent: agent.rawValue, fromModel: fromModel, toModel: body.model, at: Date().timeIntervalSince1970,
                                         mode: fellBack ? mode.rawValue : nil)

        var name: String?
        if let earlier = links.earlier(conversation, agent: agent) {
            // It saw everything up to its own handoff, which is this conversation's first prompt. A copy: the full
            // handoff below, if the resume fails, keeps that prompt.
            var unseen = turns
            if unseen.first?.user == true { unseen.removeFirst() }
            var back = parts
            back.back = true; back.goal = ""; back.branch = nil; back.failed = ""; back.next = ""; back.health = ""
            if let prompt = try? HandoffText.prompt(back, turns: unseen, message: message, limit: Self.maxReply), Hosting.promptRefusal(prompt) == nil {
                let full = HandoffText.full(back, turns: unseen, message: message)
                // Its own key: the full handoff below must not be handed this attempt's session back by the launcher.
                let started = try? await start(StartHosted(cwd: cwd, agent: agent, model: body.model, effort: body.effort, accountID: body.accountID,
                                                           prompt: prompt, resume: earlier, permissionMode: mode),
                                               images: images, key: key.map { "\($0)-back" }, origin: origin)
                // A resume the CLI refuses still makes a pane, which dies as it starts.
                if let started, await store.hosted.survivedStartup(started, resuming: earlier) {
                    name = started
                    record.resumed = true
                    do { try links.save(record, full: full, sent: prompt) } catch {
                        RemoteLog.shared("couldn't save a handoff's files: \(error.localizedDescription)")
                    }
                }
            }
        }
        if name == nil {
            let prompt: String
            do { prompt = try HandoffText.prompt(parts, turns: turns, message: message, limit: Self.maxReply) } catch {
                throw .invalid("Your message alone is longer than a reply can be. Shorten it first.", "too_long")
            }
            if let refusal = Hosting.promptRefusal(prompt) { throw .invalid(refusal, "leading_dash") }
            do { try links.save(record, full: HandoffText.full(parts, turns: turns, message: message), sent: prompt) } catch {
                RemoteLog.shared("couldn't save a handoff's files: \(error.localizedDescription)")
            }
            let started: String
            do {
                started = try await start(StartHosted(cwd: cwd, agent: agent, model: body.model, effort: body.effort, accountID: body.accountID,
                                                      prompt: prompt, permissionMode: mode), images: images, key: key, origin: origin)
            } catch {
                links.remove(record.id)
                throw error
            }
            // An expired login, a model it doesn't know: the old session stays until the new agent has outlived its start.
            guard await store.hosted.survivedStartup(started) else {
                links.remove(record.id)
                let said = await store.hosted.lastWords(started).map { " It said: \($0)" } ?? ""
                throw Failure(status: 409, code: .cannotDeliver,
                              message: "\(agent.title) stopped as it started, so \(live.provider.title) is still running.\(said)",
                              details: ["agent": agent.rawValue])
            }
            name = started
        }
        guard let name else { throw Self.internalFailure("Side A couldn't start that session.") }
        links.wait(record, hosted: name, on: store)

        var kept = false
        if let old = live.hosted, store.hosted.sessions.contains(where: { $0.name == old }) {
            do { try await store.hosted.end(old) } catch {
                kept = true
                RemoteLog.shared("couldn't end \(old) after handing it off: \(error.localizedDescription)")
            }
        } else if (await store.sessions.terminate([live], still: { _ in true }))?.isEmpty != false {
            kept = true
        }
        var link = links.link(record)
        link.kept = kept ? true : nil
        return (name, link)
    }
}
