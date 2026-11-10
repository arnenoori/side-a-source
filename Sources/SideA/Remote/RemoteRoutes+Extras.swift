import CryptoKit
import Darwin
import Foundation
import SideACore
import SideAProtocol

/// What only Side A offers (protocol, Only in Side A endpoints): quitting sessions, the Mac itself, and past
/// conversations with Side A's own pins, titles and archive. Each is gated by its capability in `Hello`.
extension RemoteRoutes {
    static let extraRoutes: [Route] = [
        Route("POST", "v1/sessions/quit-idle", quitIdle),
        Route("POST", "v1/sessions/{id}/quit", quit),
        Route("POST", "v1/mac/settings", macSettings),
        Route("GET", "v1/history", history),
        Route("POST", "v1/history/{id}", changeHistory),
        Route("GET", "v1/search", search),
        Route("POST", "v1/sessions/{id}/ports/{port}/stop", stopServer),
        Route("POST", "v1/sessions/{id}/handoff", handoff),
        Route("POST", "v1/sessions/{id}/restart", restart),
        Route("GET", "v1/cleanup", cleanupReport),
        Route("POST", "v1/cleanup/archive", archive),
        Route("POST", "v1/cleanup/restore", restore),
        Route("DELETE", "v1/worktrees/{id}", removeWorktree),
        Route("GET", "v1/autopilot", autopilot),
        Route("POST", "v1/autopilot/move", moveNow),
        Route("POST", "v1/autopilot", setAutopilot),
        Route("POST", "v1/autopilot/answers", setAutopilotAnswers),
        Route("POST", "v1/accounts/{id}/use", useAccount),
        Route("GET", "v1/approvals", approvals),
        Route("POST", "v1/update/check", checkForUpdates),
    ]

    /// Answered requests, newest first: who answered each and how.
    @Sendable static func approvals(_ context: Context) async -> HTTPResponse {
        let cursor = context.request.query["cursor"].map(Cursor.init)
        return json(200, await MainActor.run { context.controller.approvals.page(after: cursor) })
    }

    /// Sparkle's own background check. A newer version shows in Side A's menu on the Mac, as any found update does;
    /// nothing installs from here.
    @Sendable static func checkForUpdates(_ context: Context) async -> HTTPResponse {
        guard await MainActor.run(body: { context.controller.checkForUpdates?() }) == true else {
            return RemoteServer.error(503, "not_ready", "Side A can't check for updates right now.")
        }
        return HTTPResponse(status: 202)
    }

    /// Rows per history or search page.
    static let pageSize = 50

    // MARK: Quit

    /// Any interactive session: hosted ones end with their tmux session, others get SIGTERM (Claude Code saves on it).
    @Sendable static func quit(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        if let refused = await refusal(context, .quit, target: id) { return refused }
        return await command(context) { commands throws(SessionCommands.Failure) in try await commands.quit(id) }
    }

    /// Idle sessions untouched for at least the given minutes, checked again against a fresh list before each goes.
    @Sendable static func quitIdle(_ context: Context) async -> HTTPResponse {
        guard let body = context.body(QuitIdleRequest.self), body.olderThanMinutes >= 0 else { return badJSON }
        if let refused = await refusal(context, .quitIdle, body: body) { return refused }
        return await command(context) { commands throws(SessionCommands.Failure) in
            QuitIdleResult(quit: try await commands.quitIdle(olderThanMinutes: body.olderThanMinutes))
        }
    }

    // MARK: The Mac

    @Sendable static func macSettings(_ context: Context) async -> HTTPResponse {
        guard let body = context.body(MacSettings.self) else { return badJSON }
        if let refused = await refusal(context, .macSettings, body: body) { return refused }
        return await onMain(context) { store in
            if let keepAwake = body.keepAwake, keepAwake != store.keepAwake.settings.enabled { store.keepAwake.setEnabled(keepAwake) }
            let state = MacStats.state(store)
            context.controller.events?.macChanged(state)
            return json(200, state)
        }
    }

    // MARK: History

    /// Pinned conversations first (on the first page only), then the rest by last activity. `archived=true` (or `1`) lists
    /// the archive instead, which holds no pins.
    @Sendable static func history(_ context: Context) async -> HTTPResponse {
        let query = context.request.query
        let archived = ["true", "1"].contains(query["archived"] ?? "")
        guard let offset = offset(query["cursor"]) else { return RemoteServer.error(400, "bad_request", "That cursor isn't one this Mac gave out.") }
        let (pins, hidden, generation) = await MainActor.run { () -> ([String], Set<String>, Int) in
            guard let sessions = context.controller.store?.sessions else { return ([], [], 0) }
            return (sessions.pins, sessions.archived, sessions.listGeneration)
        }
        var args = ["recent", "--limit", String(offset + pageSize + 1 + (archived ? 0 : pins.count + hidden.count))]
        if let project = query["project"], !project.isEmpty { args += ["--project", project] }
        if archived { args += hidden.isEmpty ? ["--only-none"] : hidden.sorted().flatMap { ["--only", $0] } }
        if !archived, offset == 0 { args += pins.flatMap { ["--pin", $0] } }
        struct Listing: Decodable { let sessions: [SessionInfo]; let pinned: [SessionInfo]? }
        let listing: Listing
        // The rows only; pins, titles and live state come fresh from the store below.
        let key = "history " + args.joined(separator: "\u{1F}")
        do {
            listing = try SessionBridge.decode(try await context.controller.cache.value(key, ttl: 10, generation: generation) { [args] in try await bridge(context, args) },
                                               as: Listing.self)
        } catch { return failed(error) }
        let skipped = archived ? Set<String>() : hidden.union(pins)
        let rows = listing.sessions.filter { !skipped.contains($0.id) }
        let page = Array(rows.dropFirst(offset).prefix(pageSize))
        let next = rows.count > offset + pageSize ? Cursor("o\(offset + pageSize)") : nil
        return await onMain(context) { store in
            let pinned = archived || offset > 0 ? [] : (listing.pinned ?? []).filter { row in
                query["project"].map { $0.isEmpty || row.cwd == $0 } ?? true
            }
            return json(200, HistoryPage(sessions: (pinned + page).map { WireBuilders.past($0, sessions: store.sessions) }, next: next))
        }
    }

    @Sendable static func changeHistory(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        guard let change = context.body(HistoryChange.self) else { return badJSON }
        guard safeID(id) else { return RemoteServer.error(404, "session_not_found", "That conversation isn't on the Mac.") }
        if change.pinned == true, change.archived == true { return RemoteServer.error(400, "bad_request", "A conversation can't be pinned and archived.") }
        if let title = change.title, title.count > 200 { return RemoteServer.error(422, "invalid_reply", "That title is too long.") }
        struct Listing: Decodable { let sessions: [SessionInfo] }
        let found: SessionInfo
        do {
            guard let row = try SessionBridge.decode(try await bridge(context, ["recent", "--only", id]), as: Listing.self).sessions.first else {
                return RemoteServer.error(404, "session_not_found", "That conversation isn't on the Mac.")
            }
            found = row
        } catch { return failed(error) }
        return await onMain(context) { store in
            let sessions = store.sessions
            if let archived = change.archived, archived != sessions.isArchived(id) { sessions.setArchived(id, archived) }
            if let pinned = change.pinned, pinned != sessions.isPinned(id) { sessions.setPinned(id, pinned) }
            if let title = change.title {
                sessions.setTitle(id, title)
                // A live row carries the custom title too, so every phone hears the rename.
                store.remote.events?.liveChanged()
            }
            return json(200, WireBuilders.past(found, sessions: sessions))
        }
    }

    // MARK: Search

    /// The bridge's best 60 matches, in pages; archived conversations stay out, as in the Sessions window.
    @Sendable static func search(_ context: Context) async -> HTTPResponse {
        let query = context.request.query
        let text = (query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500 else { return RemoteServer.error(400, "bad_request", "Send what to search for in q.") }
        guard let offset = offset(query["cursor"]) else { return RemoteServer.error(400, "bad_request", "That cursor isn't one this Mac gave out.") }
        let limit = min(max(query["limit"].flatMap(Int.init) ?? pageSize, 1), pageSize)
        struct Listing: Decodable { let sessions: [SessionInfo] }
        let listing: Listing
        do { listing = try SessionBridge.decode(try await bridge(context, ["search", "--", text]), as: Listing.self) } catch { return failed(error) }
        return await onMain(context) { store in
            let rows = listing.sessions.filter { !store.sessions.isArchived($0.id) }
            let page = rows.dropFirst(offset).prefix(limit).map { WireBuilders.past($0, sessions: store.sessions) }
            return json(200, SearchResults(results: page, next: rows.count > offset + limit ? Cursor("o\(offset + limit)") : nil))
        }
    }

    // MARK: Stop Server

    @Sendable static func stopServer(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? "", number = context.params["port"].flatMap(Int.init)
        if let refused = await refusal(context, .stopServer, target: "\(id):\(context.params["port"] ?? "")") { return refused }
        return await command(context) { commands throws(SessionCommands.Failure) in try await commands.stopServer(id, port: number) }
    }

    // MARK: Restart Fresh

    /// A draft only, for the phone to edit and send back to `restart`.
    @Sendable static func handoff(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        return await command(context) { commands throws(SessionCommands.Failure) in try await commands.handoff(id) }
    }

    /// Starts the new hosted session first and ends the old one only once it's up, so a failed start loses nothing.
    @Sendable static func restart(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        guard let body = context.body(RestartRequest.self) else { return badJSON }
        let needs: ConfirmProof
        switch await sessionProof(context, id) {
        case .success(let proof): needs = proof
        case .failure(let unproven): return unproven.response
        }
        if let refused = await refusal(context, .restart, target: id, body: body, needs: needs) { return refused }
        let key = context.request.headers["Idempotency-Key"].map { "phone-\(context.device)-\($0)" }
        return await MainActor.run { () -> Task<HTTPResponse, Never>? in
            guard let store = context.controller.store else { return nil }
            return Task { @MainActor in
                do throws(SessionCommands.Failure) {
                    return hosted(try await SessionCommands(store: store).restart(id, body, key: key, origin: "phone"), store: store)
                } catch { return response(error) }
            }
        }?.value ?? notReady
    }

    // MARK: Clean Up

    static func cleanup(_ context: Context, _ args: [String], timeout: TimeInterval) async throws -> Data {
        let run = await MainActor.run { () -> (@MainActor @Sendable ([String], TimeInterval) async throws -> Data)? in
            if let override = context.controller.cleanupBridge { return override }
            guard let store = context.controller.store else { return nil }
            if store.isDemo {
                // Clean Up moves and deletes under HOME: a demo touches only the harness's own home, never ~/.claude.
                guard let source = store.sessions.transcriptSource else { return nil }
                return { args, timeout in
                    let run = await HostedSessions.process(source.python, [source.bridge.path, "--root", source.root.path] + args,
                                                           environment: ["HOME": source.home.path, "PATH": "/usr/bin:/bin"], timeout: timeout)
                    guard run.status == 0 else { throw BridgeFailure(message: run.errors) }
                    return Data(run.output.utf8)
                }
            }
            return { [weak store] args, timeout in
                guard let store else { throw BridgeFailure(message: "Side A is quitting.") }
                return try await store.bridgeOutput(args, timeout: timeout, priority: .userInitiated)
            }
        }
        guard let run else { throw BridgeFailure(message: "Remote is starting.") }
        return try await run(["cleanup"] + args, timeout)
    }

    /// Pinned conversations are never archived; running ones the bridge leaves alone itself.
    static func keep(_ context: Context) async -> [String] {
        await MainActor.run { context.controller.store?.sessions.pins.flatMap { ["--keep", $0] } ?? [] }
    }

    static let cleanupFailed = RemoteServer.error(503, "not_ready", "Side A couldn't look at the Mac's disk just now.", retryAfter: 10)

    @Sendable static func cleanupReport(_ context: Context) async -> HTTPResponse {
        let keep = await keep(context)
        async let d30 = cleanup(context, ["disk", "--days", "30"] + keep, timeout: 180)
        async let d60 = cleanup(context, ["disk", "--days", "60"] + keep, timeout: 180)
        async let d90 = cleanup(context, ["disk", "--days", "90"] + keep, timeout: 180)
        async let trees = cleanup(context, ["worktrees"], timeout: 300)
        struct Trees: Decodable { let worktrees: [Worktree] }
        guard let disks = try? [await d30, await d60, await d90].map({ try JSONDecoder().decode(DiskReport.self, from: $0) }),
              let found = try? JSONDecoder().decode(Trees.self, from: await trees), let all = disks.last else { return cleanupFailed }
        return json(200, CleanupReport(conversationBytes: Int(all.total), conversations: all.conversations ?? all.projects.map(\.conversations).reduce(0, +),
                                       archivable: disks.map { .init(olderThanDays: Int($0.old.days), count: $0.old.count, bytes: Int($0.old.bytes)) },
                                       archived: all.archived.count, worktrees: found.worktrees.map(Self.left)))
    }

    /// A worktree as the phone lists it: an id that doesn't show the path in URLs, and why Clean Up keeps it.
    static func left(_ tree: Worktree) -> CleanupReport.LeftWorktree {
        typealias Keep = CleanupReport.LeftWorktree.Keep
        let keep: Keep? = tree.blocked.map { label, reason in
            switch label {
            case "folder is gone": Keep(rawValue: "missing")
            case "locked": Keep(rawValue: "locked")
            case "in use": .inUse
            case "kept": reason.contains("branch") ? .noBranch : reason.contains("ignored") ? .ignoredFiles : reason.contains("session") ? .inUse : .changes
            default: .changes
            }
        }
        return .init(id: worktreeID(tree.path), path: tree.path, branch: tree.branch, keep: keep, keepReason: tree.blocked?.reason)
    }

    static func worktreeID(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    @Sendable static func archive(_ context: Context) async -> HTTPResponse {
        guard let body = context.body(ArchiveRequest.self), (1...3650).contains(body.olderThanDays) else { return badJSON }
        if let refused = await refusal(context, .archive, body: body) { return refused }
        let keep = await keep(context)
        guard let data = try? await cleanup(context, ["archive", "--days", String(body.olderThanDays)] + keep, timeout: 600),
              let count = count(data, "moved") else { return cleanupFailed }
        return json(200, CleanupResult(count: count))
    }

    @Sendable static func restore(_ context: Context) async -> HTTPResponse {
        if let refused = await refusal(context, .restore) { return refused }
        guard let data = try? await cleanup(context, ["restore"], timeout: 600), let count = count(data, "restored") else { return cleanupFailed }
        return json(200, CleanupResult(count: count))
    }

    /// How many items the bridge's answer lists under `key`.
    static func count(_ data: Data, _ key: String) -> Int? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?[key].flatMap { $0 as? [Any] }?.count
    }

    /// Never forced: the bridge checks the worktree again and refuses one with changes.
    @Sendable static func removeWorktree(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        if let refused = await refusal(context, .removeWorktree, target: id) { return refused }
        struct Trees: Decodable { let worktrees: [Worktree] }
        struct Removed: Decodable { let removed: Bool; let error: String? }
        guard let data = try? await cleanup(context, ["worktrees"], timeout: 300), let trees = try? JSONDecoder().decode(Trees.self, from: data) else {
            return cleanupFailed
        }
        guard let tree = trees.worktrees.first(where: { worktreeID($0.path) == id }) else {
            return RemoteServer.error(404, "not_found", "That worktree isn't on the Mac any more.")
        }
        let left = Self.left(tree)
        if let keep = left.keep { return RemoteServer.error(409, "worktree_kept", left.keepReason ?? "Clean Up keeps that worktree.", details: ["reason": keep.rawValue]) }
        guard let output = try? await cleanup(context, ["remove-worktree", tree.path], timeout: 60),
              let result = try? JSONDecoder().decode(Removed.self, from: output) else { return cleanupFailed }
        guard result.removed else { return RemoteServer.error(409, "worktree_kept", result.error ?? "git refused to remove it.", details: ["reason": "changes"]) }
        return HTTPResponse(status: 204)
    }

    // MARK: Autopilot

    @Sendable static func autopilot(_ context: Context) async -> HTTPResponse {
        let found = await MainActor.run { () -> (URL, AccountStore)? in context.controller.store.map { ($0.root.appendingPathComponent("runtime/autopilot.log"), $0) } }
        guard let (log, _) = found else { return notReady }
        let text = await Task.detached { Autopilot.tail(log) }.value
        return await onMain(context) { store in json(200, Autopilot.state(store, log: text)) }
    }

    @Sendable static func moveNow(_ context: Context) async -> HTTPResponse {
        if let refused = await refusal(context, .moveNow) { return refused }
        return await MainActor.run { () -> Task<HTTPResponse, Never>? in
            guard let store = context.controller.store else { return nil }
            return Task { @MainActor in
                do {
                    guard try await store.moveNow() != nil else {
                        return RemoteServer.error(409, "nothing_to_move", "Autopilot isn't holding a move right now.")
                    }
                } catch {
                    return RemoteServer.error(409, "cannot_deliver", error.localizedDescription)
                }
                let log = store.root.appendingPathComponent("runtime/autopilot.log")
                return json(200, Autopilot.state(store, log: await Task.detached { Autopilot.tail(log) }.value))
            }
        }?.value ?? notReady
    }

    static let shellSwitchingOff = RemoteServer.error(409, "cannot_deliver", "Turn on shell switching in Side A on your Mac first.",
                                                      details: ["hint": "shellSwitching"])

    /// Autopilot on or off, signed by the confirm key after Face ID over the state the user chose.
    @Sendable static func setAutopilot(_ context: Context) async -> HTTPResponse {
        guard let change = context.body(AutopilotChange.self) else { return RemoteServer.error(400, "bad_request", "Send enabled, true or false.") }
        // Turning it on would turn on shell switching, which edits the shell's startup file: only the Mac does that.
        if change.enabled, await MainActor.run(body: { context.controller.store?.shellSwitching == false }) { return shellSwitchingOff }
        guard let server = await MainActor.run(body: { context.controller.server }) else { return notReady }
        if let refusal = server.confirm(context.request, device: context.device, purpose: .autopilot,
                                        subject: ConfirmMessage.subject(autopilot: change), needs: .biometric) {
            return refusal
        }
        let found = await MainActor.run { () -> URL? in
            guard let store = context.controller.store else { return nil }
            store.setAutopilot(change.enabled)
            return store.root.appendingPathComponent("runtime/autopilot.log")
        }
        guard let log = found else { return notReady }
        let text = await Task.detached { Autopilot.tail(log) }.value
        return await onMain(context) { store in json(200, Autopilot.state(store, log: text)) }
    }

    /// Answering with the recommended choice on or off, signed by the confirm key after Face ID like Autopilot itself.
    @Sendable static func setAutopilotAnswers(_ context: Context) async -> HTTPResponse {
        guard let change = context.body(AutopilotChange.self) else { return RemoteServer.error(400, "bad_request", "Send enabled, true or false.") }
        guard let server = await MainActor.run(body: { context.controller.server }) else { return notReady }
        if let refusal = server.confirm(context.request, device: context.device, purpose: .autopilot,
                                        subject: ConfirmMessage.subject(autopilotAnswers: change), needs: .biometric) {
            return refusal
        }
        await MainActor.run { context.controller.store?.setAnswerRecommended(change.enabled) }
        return await autopilot(context)
    }

    /// Makes an account its provider's Mac-wide login, as PLAY does, signed by the confirm key after Face ID; answers
    /// with the account list. 409 `account_not_ready` for one that's signed out or whose login expired.
    @Sendable static func useAccount(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        let notFound = RemoteServer.error(404, "not_found", "That account isn't on the Mac.")
        let found = await MainActor.run { () -> (ready: Bool, shell: Bool, server: RemoteServer?)? in
            guard let store = context.controller.store, let account = store.config.accounts.first(where: { $0.id == id }) else { return nil }
            return (account.ready, account.provider != .claude || store.shellSwitching, context.controller.server)
        }
        guard let found, let subject = try? ConfirmMessage.subject(useAccount: id) else { return notFound }
        guard found.ready else {
            return RemoteServer.error(409, ErrorCode.accountNotReady.rawValue, "That account needs signing in again on the Mac before it can be used.")
        }
        // A Claude account is used through the shell line, which only the Mac turns on.
        guard found.shell else { return shellSwitchingOff }
        guard let server = found.server else { return notReady }
        if let refusal = server.confirm(context.request, device: context.device, purpose: .account, subject: subject, needs: .biometric) {
            return refusal
        }
        let failure = await MainActor.run { () -> Task<HTTPResponse?, Never>? in
            guard let store = context.controller.store else { return nil }
            return Task { @MainActor in
                do { try await store.use(id) } catch {
                    return RemoteServer.error(502, "cannot_deliver", "Side A couldn't switch to that account: \(error.localizedDescription)")
                }
                return nil
            }
        }
        guard let failure else { return notReady }
        if let response = await failure.value { return response }
        return await accounts(context)
    }

    /// History and search cursors are offsets: `o<n>`. None is the first page.
    static func offset(_ cursor: String?) -> Int? {
        guard let cursor else { return 0 }
        guard cursor.hasPrefix("o"), let value = Int(cursor.dropFirst()), (0...100_000).contains(value) else { return nil }
        return value
    }
}

/// The Mac's power and memory as the phone's Mac card shows them.
enum MacStats {
    @MainActor static func state(_ store: AccountStore) -> MacState {
        let power = store.keepAwake.power
        let level = MemoryPressure.currentLevel() ?? 1
        return MacState(onPower: power?.onAC ?? true, battery: power?.battery, memoryUsed: memoryUsed() ?? 0,
                        memoryTotal: Int(ProcessInfo.processInfo.physicalMemory),
                        memoryPressure: level >= 4 ? .critical : level >= 2 ? .warning : .normal,
                        sessionMemory: store.sessions.liveMemory << 20, keepAwake: store.keepAwake.settings.enabled,
                        worth: WireBuilders.worth(store.report?.dayModels ?? []))
    }

    /// Activity Monitor's Memory Used: app memory, wired and compressed.
    static func memoryUsed() -> Int? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = Int(stats.internal_page_count) - Int(stats.purgeable_count) + Int(stats.wire_count) + Int(stats.compressor_page_count)
        return max(pages, 0) * Int(getpagesize())
    }

    /// Whether a new reading is worth an event: anything but memory, or memory used moving by 256 MB.
    static func changed(_ old: MacState?, _ new: MacState) -> Bool {
        guard let old else { return true }
        return old.onPower != new.onPower || old.battery != new.battery || old.memoryPressure != new.memoryPressure || old.keepAwake != new.keepAwake
            || old.worth != new.worth
            || abs(old.memoryUsed - new.memoryUsed) >= 256 << 20 || abs(old.sessionMemory - new.sessionMemory) >= 256 << 20
    }
}

/// Autopilot's decisions for the phone, read back from `runtime/autopilot.log`, and the move it holds.
enum Autopilot {
    /// The log's last 64 KiB.
    static func tail(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return end > 65_536 ? String(text.drop { $0 != "\n" }.dropFirst()) : text
    }

    @MainActor static func state(_ store: AccountStore, log: String) -> AutopilotState {
        let now = Date().timeIntervalSince1970
        let name = { (id: String) in store.config.accounts.first { $0.id == id }?.name ?? id }
        let held = store.heldMoves.values.sorted { $0.since < $1.since }.map { move in
            AutopilotDecision(id: "held-\(move.from)-\(move.to)", at: move.since.timeIntervalSince1970, kind: .waiting,
                              title: "Waiting to move \(name(move.from)) → \(name(move.to))", reason: move.reason,
                              from: name(move.from), to: name(move.to), sessions: moved(store.rotationSessions(on: move.from), store: store),
                              recacheTokens: store.recacheTokens(slot: move.slot))
        }
        return AutopilotState(enabled: store.config.smartMode, pending: held.first,
                              decisions: decisions(log, records: store.rotationRecords.records, store: store),
                              answersRecommended: store.config.answerRecommended == true, held: held, next: store.nextMoves(now: now),
                              waiting: store.waitingSummary(limits: store.sessionLimits(now: now), now: now), swapAt: Int(store.config.moveAt.rounded()),
                              followFable: store.config.followFable != false, fableMode: store.fableMode)
    }

    /// A record's sessions as the phone lists them: each one's title now if it's still running, else its folder.
    @MainActor private static func moved(_ sessions: [RotationRecord.Session], store: AccountStore) -> [AutopilotDecision.Moved] {
        sessions.map { session in
            let live = store.sessions.live.first { WireBuilders.key($0) == session.id }
            let title = store.sessions.names[session.id] ?? live?.title ?? live?.name ?? session.project
            return AutopilotDecision.Moved(sessionID: session.id, title: title)
        }
    }

    /// Records say what the log can't, so each takes the place of its log line; lines from before records stay as they are.
    @MainActor static func decisions(_ log: String, records: [RotationRecord], store: AccountStore) -> [AutopilotDecision] {
        let structured = records.map { record -> AutopilotDecision in
            let id = "r\(Int(record.at))-\(record.kind.rawValue)-\(record.from)"
            let route = "\(record.from) → \(record.to ?? "")"
            let sessions = moved(record.sessions, store: store)
            return switch record.kind {
            case .moved: AutopilotDecision(id: id, at: record.at, kind: .moved, title: route, reason: record.reason, from: record.from, to: record.to, sessions: sessions)
            case .newCommands: AutopilotDecision(id: id, at: record.at, kind: .moved, title: "New commands use \(record.to ?? "")", reason: record.reason, from: record.from, to: record.to)
            case .stuck: AutopilotDecision(id: id, at: record.at, kind: .stuck, title: "\(record.from) is full, no account free", reason: record.reason, from: record.from)
            case .priorityWait: AutopilotDecision(id: id, at: record.at, kind: .priorityWait, title: "Holding \(route)", reason: record.reason, from: record.from, to: record.to)
            }
        }
        let lines = decisions(log).filter { line in
            !structured.contains { $0.kind == line.kind && $0.from == line.from && $0.to == line.to && abs($0.at - line.at) < 5 }
        }
        return Array((structured + lines).sorted { $0.at > $1.at }.prefix(50))
    }

    /// Starts the line `AccountStore.autoAnswered` writes: `Auto-answered in <session>: <answer>`.
    static let answeredPrefix = "Auto-answered in "

    /// Moves, waits, failures, primed windows and answers given by itself, newest first, at most 50. Other lines (reads, settings) are left out.
    static func decisions(_ log: String) -> [AutopilotDecision] {
        var out: [AutopilotDecision] = []
        for line in log.split(separator: "\n").reversed() where out.count < 50 {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let at = try? Date(String(parts[0]), strategy: AutopilotLog.stamp) else { continue }
            let text = String(parts[1])
            guard let decision = decision(text, at: at.timeIntervalSince1970) else { continue }
            // Its quiet seconds change the line every tick; one wait for a move is the newest one.
            if decision.kind == .waiting, let newer = out.last, newer.kind == .waiting, newer.from == decision.from, newer.to == decision.to { continue }
            out.append(decision)
        }
        return out
    }

    static func decision(_ text: String, at: Double) -> AutopilotDecision? {
        let id = SHA256.hash(data: Data("\(at) \(text)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        if text.hasPrefix("New commands: ") {
            let move = text.dropFirst("New commands: ".count)
            let names = move.components(separatedBy: " → ")
            guard names.count == 2 else { return nil }
            let to = names[1].hasSuffix(".") ? String(names[1].dropLast()) : names[1]
            let failed = to.contains(" failed")
            let target = failed ? String(to.prefix { $0 != " " }) : to
            return AutopilotDecision(id: id, at: at, kind: failed ? .failed : .moved,
                                     title: failed ? "New commands couldn't move to \(target)" : "New commands use \(target)", reason: "", from: names[0], to: target)
        }
        if text.hasPrefix(answeredPrefix), let colon = text.range(of: ": ") {
            let session = text[text.index(text.startIndex, offsetBy: answeredPrefix.count)..<colon.lowerBound]
            return AutopilotDecision(id: id, at: at, kind: .answered, title: "Answered for you in \(session)", reason: String(text[colon.upperBound...]))
        }
        if text.hasSuffix(": primed its 5-hour window.") {
            let account = String(text.dropLast(": primed its 5-hour window.".count))
            return AutopilotDecision(id: id, at: at, kind: .primed, title: "Started \(account)'s 5-hour window", reason: "", from: account)
        }
        if text.hasSuffix(" is full and no free account has room.") {
            let account = String(text.dropLast(" is full and no free account has room.".count))
            return AutopilotDecision(id: id, at: at, kind: .stuck, title: "\(account) is full, no account free", reason: "", from: account)
        }
        guard let arrow = text.range(of: " → "), let colon = text.range(of: ": ", range: arrow.upperBound..<text.endIndex) else { return nil }
        let from = String(text[..<arrow.lowerBound]), to = String(text[arrow.upperBound..<colon.lowerBound])
        let rest = String(text[colon.upperBound...])
        let kind: AutopilotDecision.Kind
        let title: String
        if rest.hasPrefix("moved") { kind = .moved; title = "Moved \(from) → \(to)" }
        else if rest.hasPrefix("waiting") { kind = .waiting; title = "Waiting to move \(from) → \(to)" }
        else if rest.hasPrefix("move failed") { kind = .failed; title = "Couldn't move \(from) → \(to)" }
        else if rest.hasPrefix("this login moved recently") { kind = .priorityWait; title = "Holding \(from) → \(to)" }
        else { return nil }
        let reason = rest.hasPrefix("moved") ? String(rest.dropFirst("moved".count)).trimmingCharacters(in: CharacterSet(charactersIn: " .()"))
            : kind == .priorityWait ? "" : rest
        return AutopilotDecision(id: id, at: at, kind: kind, title: title, reason: reason, from: from, to: to)
    }
}
