import Foundation
import SideACore
import SideAProtocol

extension RemoteRoutes {
    /// Longest reply or note, in characters.
    static let maxReply = SessionCommands.maxReply

    static let appRoutes: [Route] = [
        Route("GET", "v1/state", state),
        Route("GET", "v1/sessions", sessions),
        Route("GET", "v1/sessions/{id}", session),
        Route("POST", "v1/sessions/{id}/reply", reply),
        Route("POST", "v1/sessions/{id}/interrupt", interrupt),
        Route("POST", "v1/sessions/{id}/settings", changeSettings),
        Route("GET", "v1/models", models),
        Route("GET", "v1/sessions/{id}/turns/{turnID}/diff", turnDiff),
        Route("POST", "v1/sessions/{id}/compact", compact),
        Route("POST", "v1/sessions/{id}/review", review),
        Route("DELETE", "v1/sessions/{id}/mail", cancelMail),
        Route("GET", "v1/requests", requests),
        Route("GET", "v1/requests/{rid}", request),
        Route("POST", "v1/requests/{rid}/answer", answer),
        Route("GET", "v1/accounts", accounts),
        Route("POST", "v1/uploads", upload),
    ] + transcriptRoutes + hostedRoutes + setupRoutes + pushRoutes + previewRoutes + extraRoutes

    static let notReady = response(.notReady)
    static let noSession = response(.noSession)
    static let noRequest = RemoteServer.error(404, "request_not_found", "That request isn't open on the Mac any more.")

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

    /// Runs on the main actor with the app's store, or answers 503 while there is none.
    static func onMain(_ context: Context, _ body: @escaping @MainActor (AccountStore) -> HTTPResponse) async -> HTTPResponse {
        await MainActor.run {
            guard let store = context.controller.store else { return notReady }
            return body(store)
        }
    }

    // MARK: Lists

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
            guard let session = context.controller.events?.current().first(where: { $0.id == id || $0.conversationID == id }) else { return noSession }
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

    // MARK: Answer

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
                        return RemoteServer.error(409, "gate_changed", "This request needs more now than when you saw it. Look again.",
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
                return RemoteServer.error(409, "already_resolved", alreadyResolved(resolution), details: details)
            case .refused(let reason):
                return RemoteServer.error(422, "invalid_answer", refusal(reason), details: ["reason": reason])
            }
        }
    }

    static func alreadyResolved(_ resolution: RequestResolution) -> String {
        switch resolution.by {
        case .device: "This was already answered on \(resolution.deviceName ?? "another iPhone")."
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

    // MARK: Talk

    typealias Target = SessionCommands.Target

    /// The error answer for a command's failure, in the words the Sessions window shows too.
    static func response(_ failure: SessionCommands.Failure) -> HTTPResponse {
        RemoteServer.error(failure.status, failure.code, failure.message, details: failure.details, retryAfter: failure.retryAfter)
    }

    /// Runs a command on the main actor with the app's store: its value as JSON, or its failure.
    static func command<T: Encodable & Sendable>(_ context: Context, status: Int = 200,
                                                 _ body: @escaping @MainActor (SessionCommands) async throws(SessionCommands.Failure) -> T) async -> HTTPResponse {
        await MainActor.run { () -> Task<HTTPResponse, Never>? in
            guard let store = context.controller.store else { return nil }
            return Task { @MainActor in
                do throws(SessionCommands.Failure) { return json(status, try await body(SessionCommands(store: store))) } catch { return response(error) }
            }
        }?.value ?? notReady
    }

    /// A command with nothing to say back: 204, or its failure.
    static func command(_ context: Context, _ body: @escaping @MainActor (SessionCommands) async throws(SessionCommands.Failure) -> Void) async -> HTTPResponse {
        await MainActor.run { () -> Task<HTTPResponse, Never>? in
            guard let store = context.controller.store else { return nil }
            return Task { @MainActor in
                do throws(SessionCommands.Failure) {
                    try await body(SessionCommands(store: store))
                    return HTTPResponse(status: 204)
                } catch { return response(error) }
            }
        }?.value ?? notReady
    }

    @Sendable static func reply(_ context: Context) async -> HTTPResponse {
        guard let reply = context.body(RemoteReply.self) else { return badJSON }
        let id = context.params["id"] ?? ""
        guard let root = await MainActor.run(body: { context.controller.store?.root }) else { return notReady }
        guard let images = RemoteUploads.paths(reply.attachments, root: root) else {
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
        if let refused { return refused }
        let message = SessionCommands.Message(text: reply.text, images: images, mode: reply.mode, keys: reply.keys, turnID: reply.turnID, submit: reply.submit,
                                              origin: Island.QueuedFollowUp.Origin(device: context.device, proven: needs))
        let plan = await MainActor.run { () -> SessionCommands.Plan in
            guard let store = context.controller.store else { return .failed(.notReady) }
            let commands = SessionCommands(store: store)
            // What was just proven was judged a moment ago; a session that asks more now doesn't take it.
            if let now = commands.permissionMode(id), ConfirmProof(ConfirmPolicy.reply(reply, sessionMode: now)) > needs {
                return .failed(SessionCommands.Failure(status: 409, code: "gate_changed", message: "This session needs more now than when you sent this. Send it again."))
            }
            return commands.prepare(id, message)
        }
        return await command(context) { commands throws(SessionCommands.Failure) in try await commands.send(plan, message) }
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
        case .failure(.unsupported): return RemoteServer.error(415, "unsupported_media", "Send a HEIC, JPEG, PNG, GIF or WebP photo.")
        case .failure(.unreadable): return RemoteServer.error(415, "unsupported_media", "That photo couldn't be read.")
        case .failure(.full): return RemoteServer.error(413, "uploads_full", "This iPhone's photos have filled their space on the Mac. Try again once the oldest clear, 7 days after they were sent.")
        }
    }

    static func hostedError(_ error: HostedError) -> HTTPResponse { response(.hosted(error)) }

    @Sendable static func interrupt(_ context: Context) async -> HTTPResponse {
        let when: InterruptRequest.When
        if context.request.body.isEmpty { when = .now } else {
            guard let body = context.body(InterruptRequest.self), [.now, .nextStep].contains(body.when) else { return badJSON }
            when = body.when
        }
        let id = context.params["id"] ?? ""
        return await command(context) { commands throws(SessionCommands.Failure) in try await commands.interrupt(id, when: when) }
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

    static func invalidReply(_ message: String, _ reason: String) -> HTTPResponse { response(.invalid(message, reason)) }
}
