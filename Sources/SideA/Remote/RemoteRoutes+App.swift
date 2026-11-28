import Foundation
import SideACore
import SideAProtocol
import UniformTypeIdentifiers

extension RemoteRoutes {
    static let appRoutes: [Route] = [
        Route("GET", "v1/state", state),
        Route("GET", "v1/sessions", sessions),
        Route("GET", "v1/sessions/{id}", session),
        Route(QueuedRoutes.reply.method, QueuedRoutes.reply.pattern, reply),
        Route(QueuedRoutes.interrupt.method, QueuedRoutes.interrupt.pattern, interrupt),
        Route("POST", "v1/sessions/{id}/settings", changeSettings),
        Route("GET", "v1/models", models),
        Route("GET", "v1/sessions/{id}/turns/{turnID}/diff", turnDiff),
        Route("POST", "v1/sessions/{id}/compact", compact),
        Route("POST", "v1/sessions/{id}/review", review),
        Route(QueuedRoutes.takeBack.method, QueuedRoutes.takeBack.pattern, cancelMail),
        Route("DELETE", "v1/sessions/{id}/queue/{qid}", removeQueued),
        Route("GET", "v1/sessions/{id}/files", files),
        Route("GET", "v1/sessions/{id}/file", file),
        Route("GET", "v1/requests", requests),
        Route("GET", "v1/requests/{rid}", request),
        Route(QueuedRoutes.answer.method, QueuedRoutes.answer.pattern, answer),
        Route("GET", "v1/accounts", accounts),
        Route("POST", "v1/uploads", upload),
    ] + transcriptRoutes + hostedRoutes + setupRoutes + pushRoutes + previewRoutes + extraRoutes + transcribeRoutes + snoozeRoutes + moveRoutes + computerRoutes

    static let notReady = response(.notReady)
    static let noSession = response(.noSession)
    static let noRequest = RemoteServer.error(404, .requestNotFound, "That request isn't open on the Mac any more.")

    /// Builds a list on the main actor and reads `seq` on the server's queue right after. Events recorded before the
    /// build are already queued ahead of the read, so the list reflects every event up to `seq` and none after it.
    static func listed<T: Sendable>(_ context: Context, _ build: @escaping @MainActor (AccountStore) -> T) async -> (value: T, seq: Int, epoch: String)? {
        await withCheckedContinuation { done in
            Task { @MainActor in
                guard let store = context.controller.store, let hub = context.controller.hub, let queue = context.controller.server?.queue else {
                    return done.resume(returning: nil)
                }
                let value = build(store)
                queue.async { done.resume(returning: (value, hub.seq, hub.epoch)) }
            }
        }
    }

    static func onMain(_ context: Context, _ body: @escaping @MainActor (AccountStore) -> HTTPResponse) async -> HTTPResponse {
        await MainActor.run {
            guard let store = context.controller.store else { return notReady }
            return body(store)
        }
    }

    static func onMainAsync(_ context: Context, _ body: @escaping @MainActor (AccountStore) async -> HTTPResponse) async -> HTTPResponse {
        await MainActor.run { () -> Task<HTTPResponse, Never>? in
            guard let store = context.controller.store else { return nil }
            return Task { @MainActor in await body(store) }
        }?.value ?? notReady
    }

    @Sendable static func state(_ context: Context) async -> HTTPResponse {
        guard let list = await listed(context, { _ in context.controller.events?.snapshot() }), let build = list.value else { return notReady }
        return json(200, build(list.seq, list.epoch).scoped(to: context.device))
    }

    @Sendable static func sessions(_ context: Context) async -> HTTPResponse {
        guard let list = await listed(context, { store in
            (context.controller.events?.current() ?? [], store.island.ready.compactMap { WireBuilders.finished($0, island: store.island) })
        }) else { return notReady }
        return json(200, SideAProtocol.SessionList(sessions: list.value.0, finished: list.value.1, seq: list.seq))
    }

    @Sendable static func requests(_ context: Context) async -> HTTPResponse {
        guard let list = await listed(context, { store in store.island.pending.map(WireBuilders.request) }) else { return notReady }
        return json(200, RequestList(requests: list.value, seq: list.seq))
    }

    @Sendable static func accounts(_ context: Context) async -> HTTPResponse {
        guard let list = await listed(context, WireBuilders.accounts) else { return notReady }
        return json(200, AccountList(accounts: list.value, seq: list.seq))
    }

    @Sendable static func session(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        return await onMain(context) { _ in
            guard let session = context.controller.events?.session(id) else { return noSession }
            return json(200, session)
        }
    }

    @Sendable static func request(_ context: Context) async -> HTTPResponse {
        let rid = context.params["rid"]?.lowercased() ?? ""
        return await onMain(context) { store in
            guard let item = store.island.pending.first(where: { $0.id.uuidString.lowercased() == rid }) else { return noRequest }
            return json(200, WireBuilders.fullRequest(item))
        }
    }

    @Sendable static func answer(_ context: Context) async -> HTTPResponse {
        guard let body = context.body(AnswerBody.self) else { return badJSON }
        let rid = context.params["rid"] ?? ""
        let subject: String?
        do {
            subject = try body.mode.map { try ConfirmMessage.subject(requestID: rid.lowercased(), allowMode: $0) }
                ?? ConfirmMessage.subject(requestID: rid.lowercased(), answer: body.answer)
        } catch { return noRequest }
        // The Mac's own gate, judged now, decides what the phone must prove; the phone's confirmDestructive is ignored.
        var proven = ConfirmProof.none
        if let subject, let (gate, needs, server) = await MainActor.run(body: { () -> (AllowGate, ConfirmProof, RemoteServer?)? in
            guard let judged = context.controller.store?.island.remoteNeeds(rid, body.answer, mode: body.mode) else { return nil }
            return (judged.gate, judged.needs, context.controller.server)
        }) {
            if needs > .none {
                guard let server else { return notReady }
                if let refusal = server.confirm(context.request, device: context.device, purpose: .allow, subject: subject, needs: needs) {
                    if let shown = ShownGates.shared[UUID(uuidString: rid) ?? UUID()], ConfirmProof(shown) < needs {
                        return RemoteServer.error(409, .gateChanged, "This request needs more now than when you saw it. Look again.",
                                                  details: ["gate": gate.rawValue])
                    }
                    return refusal
                }
                proven = needs
            }
        }
        return await onMain(context) { store in
            let name = context.controller.devices.devices.first { $0.id == context.device }?.name ?? "iPhone"
            switch store.island.remoteAnswer(rid, body.answer, mode: body.mode, device: context.device, name: name, proven: proven) {
            case .done(let resolution): return json(200, resolution)
            case .unknown: return noRequest
            case .conflict(let resolution):
                var details = ["by": resolution.by.rawValue]
                if let answer = resolution.answer { details["answer"] = answer.rawValue }
                if let name = resolution.deviceName { details["deviceName"] = name }
                return RemoteServer.error(409, .alreadyResolved, alreadyResolved(resolution), details: details)
            case .refused(let reason):
                return RemoteServer.error(422, .invalidAnswer, refusal(reason), details: ["reason": reason])
            }
        }
    }

    static func alreadyResolved(_ resolution: RequestResolution) -> String {
        switch resolution.by {
        case .device: "This was already answered on \(resolution.deviceName ?? "another device")."
        case .mac: "This was already answered on the Mac."
        case .terminal: "This was already answered in the terminal."
        case .handedBack: "This was handed back to the terminal."
        case .autoAnswered: "Side A answered this with the recommended choice after a minute."
        default: "This request is already closed."
        }
    }

    static func refusal(_ reason: String) -> String {
        switch RemoteAnswers.Refusal(rawValue: reason) {
        case .notAllowed?: "This request doesn't take that answer."
        case .needsConfirm?: "Confirm this one with Face ID first."
        case .unknownSuggestion?: "That rule isn't offered for this request any more."
        case .unknownOption?: "One of those choices isn't an option here."
        case .incomplete?: "Answer every question first."
        case .tooLong?: "That answer is too long."
        case nil: "Side A can't take that answer."
        }
    }

    typealias Target = SessionCommands.Target

    static func response(_ failure: SessionCommands.Failure) -> HTTPResponse {
        RemoteServer.error(failure.status, failure.code, failure.message, details: failure.details, retryAfter: failure.retryAfter)
    }

    static func command<T: Encodable & Sendable>(_ context: Context, status: Int = 200,
                                                 _ body: @escaping @MainActor (SessionCommands) async throws(SessionCommands.Failure) -> T) async -> HTTPResponse {
        await onMainAsync(context) { store in
            do throws(SessionCommands.Failure) { return json(status, try await body(SessionCommands(store: store))) } catch { return response(error) }
        }
    }

    static func command(_ context: Context, _ body: @escaping @MainActor (SessionCommands) async throws(SessionCommands.Failure) -> Void) async -> HTTPResponse {
        await onMainAsync(context) { store in
            do throws(SessionCommands.Failure) {
                try await body(SessionCommands(store: store))
                return HTTPResponse(status: 204)
            } catch { return response(error) }
        }
    }

    @Sendable static func reply(_ context: Context) async -> HTTPResponse {
        guard let reply = context.body(RemoteReply.self) else { return badJSON }
        let id = context.params["id"] ?? ""
        guard let root = await MainActor.run(body: { context.controller.store?.root }) else { return notReady }
        guard let images = RemoteUploads.paths(reply.attachments, root: root, device: context.device) else {
            return invalidReply("A photo in this reply is no longer on the Mac. Attach it again.", "unknown_upload")
        }
        // Before the plan, which already delivers a note or a follow-up. A session that appears after this look is refused, never unsigned.
        let mode = await MainActor.run { () -> PermissionMode?? in context.controller.store.flatMap { SessionCommands(store: $0).permissionMode(id) } }
        guard let mode else { return noSession }
        let needs = ConfirmProof(ConfirmPolicy.reply(reply, sessionMode: mode))
        let refused: HTTPResponse?
        if reply.mode == .keys {
            guard let subject = try? ConfirmMessage.subject(sessionID: id, keys: reply.keys ?? []) else { return noSession }
            refused = await refusal(context, .keys, subject: subject, needs: needs)
        } else {
            refused = await refusal(context, .reply, target: id, body: reply, needs: needs)
        }
        if let refused { return noted(refused, key: context.request.headers["Idempotency-Key"], session: id) }
        await MainActor.run { if let row = context.controller.events?.session(id) { context.controller.snoozes.wake(row.id) } }
        var message = SessionCommands.Message(text: reply.text, images: images, mode: reply.mode, keys: reply.keys, turnID: reply.turnID, submit: reply.submit,
                                              origin: Island.QueuedFollowUp.Origin(device: context.device, proven: needs))
        message.replaces = reply.replaces
        message.seen = reply.seen
        message.promotes = reply.promotes
        message.idempotencyKey = context.request.headers["Idempotency-Key"]
        let plan = await MainActor.run { () -> SessionCommands.Plan in
            guard let store = context.controller.store else { return .failed(.notReady) }
            let commands = SessionCommands(store: store)
            if let now = commands.permissionMode(id), ConfirmProof(ConfirmPolicy.reply(reply, sessionMode: now)) > needs {
                return .failed(SessionCommands.Failure(status: 409, code: .gateChanged, message: "This session needs more now than when you sent this. Send it again."))
            }
            return commands.prepare(id, message)
        }
        if let conversation = await conversation(context) {
            SentReplies.shared.record(conversation: conversation, key: message.idempotencyKey, text: reply.text)
        }
        let key = message.idempotencyKey
        let sent = await command(context) { commands throws(SessionCommands.Failure) in try await commands.send(plan, message) }
        return noted(sent, key: key, session: id)
    }

    private static func noted(_ response: HTTPResponse, key: String?, session: String) -> HTTPResponse {
        RemoteLog.shared("reply \(key?.prefix(8) ?? "-") for session \(session.prefix(8)) \(replyOutcome(response))")
        return response
    }

    /// What the log says became of a reply: how it was delivered or why it wasn't, never its words.
    static func replyOutcome(_ response: HTTPResponse) -> String {
        guard response.status == 200 else {
            let error = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["error"] as? [String: Any]
            return "refused \(response.status) \(error?["code"] as? String ?? "")"
        }
        let delivery = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["delivery"] as? String
        return "accepted as \(delivery ?? "typed")"
    }

    @Sendable static func upload(_ context: Context) async -> HTTPResponse {
        guard let root = await MainActor.run(body: { context.controller.store?.root }) else { return notReady }
        let body = context.request.body, device = context.device
        let result = await Task.detached { () -> Result<Upload, RemoteUploads.Failure> in
            RemoteUploads.sweep(root: root)
            do throws(RemoteUploads.Failure) { return .success(try RemoteUploads.store(body, root: root, device: device)) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let upload): return json(201, upload)
        case .failure(.unsupported): return RemoteServer.error(415, .unsupportedMedia, "Send a HEIC, JPEG, PNG, GIF or WebP photo.")
        case .failure(.unreadable): return RemoteServer.error(415, .unsupportedMedia, "That photo couldn't be read.")
        case .failure(.full): return RemoteServer.error(413, .uploadsFull, "This device's photos have filled their space on the Mac. Try again once the oldest clear, 7 days after they were sent.")
        }
    }

    static func hostedError(_ error: HostedError) -> HTTPResponse { response(.hosted(error)) }

    @Sendable static func interrupt(_ context: Context) async -> HTTPResponse {
        var when = InterruptRequest.When.now, send = false, resend = false
        if !context.request.body.isEmpty {
            guard let body = context.body(InterruptRequest.self), [.now, .nextStep].contains(body.when) else { return badJSON }
            when = body.when
            send = body.send == true
            resend = body.resend == true
        }
        let id = context.params["id"] ?? ""
        return await command(context) { commands throws(SessionCommands.Failure) in try await commands.interrupt(id, when: when, send: send, resend: resend) }
    }

    @Sendable static func cancelMail(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        return await onMain(context) { store in
            do throws(SessionCommands.Failure) {
                try SessionCommands(store: store).takeBack(id)
                return HTTPResponse(status: 204)
            } catch { return response(error) }
        }
    }

    /// Takes a waiting reply out of the session's queue. Taking back needs no more than the pairing, as Take Back does.
    @Sendable static func removeQueued(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? "", reply = context.params["qid"] ?? ""
        return await onMain(context) { store in
            guard let target = SessionCommands.Target(id, store: store), let conversation = target.conversation else { return response(.noSession) }
            return store.island.removeQueued(conversation, id: reply) ? HTTPResponse(status: 204) : response(.queueChanged)
        }
    }

    @Sendable static func files(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? "", query = context.request.query["q"] ?? ""
        let folder = await MainActor.run { context.controller.store.flatMap { SessionCommands.Target(id, store: $0)?.live?.cwd } }
        guard let folder else { return noSession }
        return json(200, FileMatches(files: await FileMentions.shared.matches(query, in: folder)))
    }

    /// One file under the session's folder, as its bytes (`FileReads`). The pairing is enough, as for the transcript and
    /// its diffs, which already carry what the agent read and wrote.
    @Sendable static func file(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? "", path = context.request.query["path"] ?? ""
        guard !path.isEmpty, !path.contains("\0") else { return RemoteServer.error(400, .badRequest, "Send the file's path.") }
        let folder = await MainActor.run { context.controller.store.flatMap { SessionCommands.Target(id, store: $0)?.live?.cwd } }
        guard let folder else { return noSession }
        switch await FileReads.read(path, in: folder) {
        case .success(let data):
            let type = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            return HTTPResponse(status: 200, headers: HTTPHeaders([("Content-Type", type), ("Cache-Control", "private, no-store")]), body: data)
        case .failure(.missing): return RemoteServer.error(404, .fileNotFound, "That file isn't in this session's folder.")
        case .failure(.folder): return RemoteServer.error(404, .fileNotFound, "That's a folder, not a file.")
        case .failure(.tooLarge): return RemoteServer.error(413, .tooLarge, "That file is over \(FileReads.most >> 20) MB, too big to open on the phone.")
        case .failure(.refused(let reason)):
            RemoteLog.shared("refused a file read (\(reason.rawValue)) for device \(context.device.prefix(6))")
            return RemoteServer.error(403, .fileRefused, fileRefusal(reason), details: ["reason": reason.rawValue])
        }
    }

    static func fileRefusal(_ reason: FileReads.Refusal) -> String {
        switch reason {
        case .outside: "That file is outside this session's folder."
        case .secret: "Side A doesn't send keys, credentials or anything in .git."
        case .linked: "This file is linked from elsewhere on the Mac, so Side A doesn't send it."
        }
    }

    static func invalidReply(_ message: String, _ reason: String) -> HTTPResponse { response(.invalid(message, reason)) }

    @Sendable static func changeSettings(_ context: Context) async -> HTTPResponse {
        guard let change = context.body(SettingsChange.self) else { return badJSON }
        let id = context.params["id"] ?? ""
        let subject: String
        do { subject = try ConfirmMessage.subject(sessionID: id, settings: change) } catch { return noSession }
        if let refusal = await refusal(context, .settings, subject: subject, needs: change.raises ? .biometric : .unlock) { return refusal }
        return await command(context) { commands throws(SessionCommands.Failure) in try await commands.settings(id, change) }
    }

    @Sendable static func models(_ context: Context) async -> HTTPResponse {
        guard let agent = AgentProvider(rawValue: context.request.query["kind"] ?? "claude") else {
            return RemoteServer.error(400, .badRequest, "kind is claude or codex.")
        }
        let session = context.request.query["session"]
        let live = await command(context) { commands throws(SessionCommands.Failure) in try await commands.models(agent, session: session) }
        if live.status != 200 || live.body != Data("null".utf8) { return live }
        guard let options = await RemoteOptions.agents(context.controller) else { return notReady }
        return json(200, ModelList(agent: agent, models: options.first { $0.agent == agent }?.models ?? []))
    }

    @Sendable static func turnDiff(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? "", turn = context.params["turnID"] ?? ""
        return await command(context) { commands throws(SessionCommands.Failure) in try await commands.turnDiff(id, turn: turn) }
    }

    @Sendable static func compact(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        if let refused = await refusal(context, .compact, target: id) { return refused }
        return empty(await command(context, status: 204) { commands throws(SessionCommands.Failure) in try await commands.compact(id); return Empty() })
    }

    @Sendable static func review(_ context: Context) async -> HTTPResponse {
        guard let request = context.body(ReviewRequest.self) else { return badJSON }
        let id = context.params["id"] ?? ""
        if let refused = await refusal(context, .review, target: id, body: request) { return refused }
        return empty(await command(context, status: 204) { commands throws(SessionCommands.Failure) in try await commands.review(id, request); return Empty() })
    }

    struct Empty: Encodable, Sendable {}

    /// A 204 has no body.
    private static func empty(_ response: HTTPResponse) -> HTTPResponse { response.status == 204 ? HTTPResponse(status: 204) : response }
}
