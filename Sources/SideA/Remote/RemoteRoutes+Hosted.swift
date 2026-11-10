import Foundation
import SideACore
import SideAProtocol

/// Sessions Side A hosts in tmux, and the folders a phone may start one in: the projects of the last two months'
/// sessions, never a path the phone made up.
extension RemoteRoutes {
    static let hostedRoutes: [Route] = [
        Route("GET", "v1/projects", projects),
        Route("GET", "v1/hosted", hostedList),
        Route("POST", "v1/hosted", startHosted),
        Route("DELETE", "v1/hosted/{name}", endHosted),
        Route("POST", "v1/hosted/{name}/trust", trustHosted),
        Route("POST", "v1/sessions/{id}/continue", continueOnPhone),
    ]

    static let tmuxMissing = RemoteServer.error(503, "tmux_missing", "Hosted sessions need tmux, which comes with Side A. Reinstall Side A on the Mac.", retryAfter: 60)

    // MARK: Projects

    @Sendable static func projects(_ context: Context) async -> HTTPResponse {
        json(200, ProjectList(projects: await RemoteProjects.list(context.controller)))
    }

    // MARK: Hosted

    @Sendable static func hostedList(_ context: Context) async -> HTTPResponse {
        guard await MainActor.run(body: { context.controller.store?.hosted.available }) == true else { return tmuxMissing }
        guard let list = await listed(context, WireBuilders.hostedSessions) else { return notReady }
        return json(200, HostedList(hosted: list.value, seq: list.seq))
    }

    @Sendable static func startHosted(_ context: Context) async -> HTTPResponse {
        guard let body = context.body(StartHosted.self) else { return badJSON }
        if let refused = Hosting.promptRefusal(body.prompt) { return invalidReply(refused, "leading_dash") }
        guard await MainActor.run(body: { context.controller.store?.hosted.available }) == true else { return tmuxMissing }
        guard await RemoteProjects.list(context.controller).contains(where: { $0.path == body.cwd }) else {
            return RemoteServer.error(404, "not_found", "That folder isn't one of the Mac's projects.")
        }
        if let resume = body.resume, !IDs.safe(resume) { return RemoteServer.error(404, "session_not_found", "That conversation isn't on the Mac.") }
        guard (body.prompt ?? "").count <= SessionCommands.maxReply else { return invalidReply("That prompt is too long.", "too_long") }
        if body.effort != nil, let options = await RemoteOptions.agents(context.controller),
           let refusal = RemoteOptions.refusal(effort: body.effort, model: body.model, agent: body.agent, options: options) {
            return RemoteServer.error(422, "invalid_option", refusal)
        }
        if let mode = body.permissionMode {
            guard Hosting.permissionArguments(body.agent == .codex ? .codex : .claude, mode: mode.rawValue) != nil else {
                return RemoteServer.error(422, "invalid_option", "\(body.agent == .codex ? "Codex" : "Claude") can't start in that mode.")
            }
        }
        // Signed over the whole start: an unlocked phone, or Face ID for a permissive mode or a shell prompt.
        guard let subject = try? ConfirmMessage.subject(start: body) else { return badJSON }
        if let refused = await refusal(context, .settings, subject: subject, needs: ConfirmProof(ConfirmPolicy.start(body))) { return refused }
        guard let root = await MainActor.run(body: { context.controller.store?.root }),
              let images = RemoteUploads.paths(body.attachments, root: root) else {
            return invalidReply("A photo for this session is no longer on the Mac. Attach it again.", "unknown_upload")
        }
        let key = context.request.headers["Idempotency-Key"].map { "phone-\(context.device)-\($0)" }
        return await onMainAsync(context) { store in await start(body, images: images, key: key, store: store) }
    }

    @MainActor static func start(_ start: StartHosted, images: [String], key: String?, store: AccountStore) async -> HTTPResponse {
        do throws(SessionCommands.Failure) {
            return hosted(try await SessionCommands(store: store).start(start, images: images, key: key, origin: "phone"), store: store)
        } catch { return response(error) }
    }

    /// A session just started (201) or answered (200), as the phone gets it.
    @MainActor static func hosted(_ name: String, store: AccountStore, status: Int = 201) -> HTTPResponse {
        guard let session = store.hosted.sessions.first(where: { $0.name == name }),
              let wire = WireBuilders.hosted(session, hosted: store.hosted, store: store, viewers: 0) else {
            return RemoteServer.error(500, "internal", "The session started but Side A lost track of it.")
        }
        return json(status, wire)
    }

    @Sendable static func endHosted(_ context: Context) async -> HTTPResponse {
        let name = context.params["name"] ?? ""
        if let refused = await refusal(context, .endHosted, target: name) { return refused }
        return await onMainAsync(context) { store in
            do {
                try await store.hosted.end(name)
                return HTTPResponse(status: 204)
            } catch HostedError.notHosted {
                return RemoteServer.error(404, "not_found", "That hosted session isn't running.")
            } catch let error as HostedError {
                return hostedError(error)
            } catch {
                return RemoteServer.error(500, "internal", "Side A couldn't end that session.")
            }
        }
    }

    /// Trust and start: the hosted session's folder-trust question answered Yes. Signed by the confirm key after Face
    /// ID over the name and the folder the phone showed; 409 when no trust question for that folder is on screen.
    @Sendable static func trustHosted(_ context: Context) async -> HTTPResponse {
        let name = context.params["name"] ?? ""
        let cwd = await MainActor.run { context.controller.store?.hosted.sessions.first(where: { $0.name == name && $0.agent != nil })?.cwd }
        guard let cwd, let subject = try? ConfirmMessage.subject(trust: name, cwd: cwd) else {
            return RemoteServer.error(404, "not_found", "That hosted session isn't running.")
        }
        if let refusal = await refusal(context, .trust, subject: subject, needs: .biometric) { return refusal }
        return await onMainAsync(context) { store in
            do {
                try await store.hosted.trust(name)
                await store.hosted.refresh()
                return hosted(name, store: store, status: 200)
            } catch HostedError.notHosted {
                return RemoteServer.error(404, "not_found", "That hosted session isn't running.")
            } catch let error as HostedError {
                return hostedError(error)
            } catch {
                return RemoteServer.error(500, "internal", "Side A couldn't answer that session's question.")
            }
        }
    }

    /// Continue on phone: ends the Mac process and resumes the conversation in tmux (hosting.md).
    @Sendable static func continueOnPhone(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        let needs: ConfirmProof
        switch await sessionProof(context, id) {
        case .success(let proof): needs = proof
        case .failure(let unproven): return unproven.response
        }
        if let refused = await refusal(context, .continue, target: id, needs: needs) { return refused }
        return await onMainAsync(context) { store in
            guard store.hosted.available else { return tmuxMissing }
            guard let target = Target(id, store: store), let live = target.live else {
                return RemoteServer.error(404, "session_not_found", "That session isn't running on the Mac.")
            }
            if let name = live.hosted, let session = store.hosted.sessions.first(where: { $0.name == name }),
               let wire = WireBuilders.hosted(session, hosted: store.hosted, store: store, viewers: 0) { return json(200, wire) }
            if let refusal = HostedSessions.continueRefusal(live) { return RemoteServer.error(409, "cannot_deliver", refusal) }
            let home = store.sessions.transcriptSource?.home ?? FileManager.default.homeDirectoryForCurrentUser
            let transcript = live.provider == .claude ? live.sessionID.flatMap { RemoteRoutes.claudeTranscript($0, home: home) } : nil
            do {
                let name = try await store.hosted.continueHere(live, transcript: transcript, registry: home.appendingPathComponent(".claude/sessions")) { environment in
                    store.accountID(codexHome: ProcessEnvironment.codexHome(environment, root: store.root.path, home: home.path))
                }
                guard let session = store.hosted.sessions.first(where: { $0.name == name }),
                      let wire = WireBuilders.hosted(session, hosted: store.hosted, store: store, viewers: 0) else {
                    return RemoteServer.error(500, "internal", "The session moved but Side A lost track of it.")
                }
                return json(200, wire)
            } catch let error as HostedError {
                return hostedError(error)
            } catch {
                return RemoteServer.error(500, "internal", "Side A couldn't continue that session.")
            }
        }
    }

    static func claudeTranscript(_ id: String, home: URL) -> URL? {
        guard IDs.safe(id) else { return nil }
        let projects = home.appendingPathComponent(".claude/projects")
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.map { $0.appendingPathComponent("\(id).jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

enum RemoteProjects {
    /// The folders of the last two months' sessions, newest first, with their git branches: the phone's New Session
    /// list and the Sessions window's.
    static func list(_ controller: RemoteController) async -> [RemoteProject] {
        struct Recent: Decodable { let sessions: [SessionInfo] }
        guard let store = await MainActor.run(body: { controller.store }) else { return [] }
        let generation = await MainActor.run { store.sessions.listGeneration }
        let args = ["recent", "--days", "60", "--limit", "500"]
        guard let data = try? await controller.cache.value("projects", ttl: 15, generation: generation, { try await store.sessions.remoteReply(args) }),
              let recent = try? SessionBridge.decode(data, as: Recent.self) else { return [] }
        let (live, root) = await MainActor.run { (store.sessions.live, store.root.path) }
        var last: [String: Double] = [:]
        for session in recent.sessions {
            guard let cwd = session.cwd, cwd != root else { continue }
            last[cwd] = max(last[cwd] ?? 0, session.lastTs ?? 0)
        }
        let folders = Array(last.sorted { $0.value > $1.value }.map(\.key).filter { FileManager.default.fileExists(atPath: $0) }.prefix(50))
        let gits = await Self.gits(folders, cache: controller.cache)
        return zip(folders, gits).map { path, git in
            RemoteProject(path: path, name: URL(fileURLWithPath: path).lastPathComponent, gitRoot: git.root, branch: git.branch,
                          branches: git.branches, lastUsedAt: last[path].flatMap { $0 > 0 ? $0 : nil },
                          liveSessions: live.filter { $0.cwd == path }.count)
        }
    }

    /// What `sidea use <name>` takes for a Claude account: the bridge's `pin_name`.
    static func pin(_ name: String) -> String {
        let slug = name.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.joined(separator: "-")
        return slug.isEmpty ? "account" : slug
    }

    typealias Git = (root: String?, branch: String?, branches: [String])

    /// Each folder's `git`, eight at a time, each kept half a minute: three git runs a folder add up over fifty folders.
    static func gits(_ paths: [String], cache: RemoteCache) async -> [Git] {
        await withTaskGroup(of: (Int, Git).self) { group in
            var out = [Git](repeating: (nil, nil, []), count: paths.count)
            for (index, path) in paths.enumerated() {
                if index >= 8, let (done, git) = await group.next() { out[done] = git }
                group.addTask {
                    let git = try? await cache.value("git " + path, ttl: 30) { () async -> Git in
                        await withCheckedContinuation { done in DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: git(path)) } }
                    }
                    return (index, git ?? (nil, nil, []))
                }
            }
            for await (done, git) in group { out[done] = git }
            return out
        }
    }

    /// The repository a folder is in, its branch, and its 20 most recently committed branches.
    static func git(_ path: String) -> Git {
        guard var root = run(["-C", path, "rev-parse", "--show-toplevel"]) else { return (nil, nil, []) }
        // Git answers with symlinks resolved; the root keeps the folder's own spelling, as the phone was given it.
        let real = realpath(path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) } ?? path
        if real.hasPrefix(root), path.hasSuffix(real.dropFirst(root.count)) { root = String(path.dropLast(real.count - root.count)) }
        let branch = run(["-C", path, "branch", "--show-current"]).flatMap { $0.isEmpty ? nil : $0 }
        let branches = run(["-C", path, "for-each-ref", "--sort=-committerdate", "--count=20", "--format=%(refname:short)", "refs/heads"])?
            .split(separator: "\n").map(String.init) ?? []
        return (root, branch, branches)
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_OPTIONAL_LOCKS": "0"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
