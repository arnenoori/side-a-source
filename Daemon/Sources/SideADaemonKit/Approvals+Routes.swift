import Foundation
import SideACore
import SideAProtocol

/// `GET /v1/requests`, `GET /v1/requests/{rid}` and `POST /v1/requests/{rid}/answer`, as the Mac serves them, and the open
/// requests in the state snapshot. There is no capability for a plain Allow or Deny: the phone shows whatever `requests` holds.
public final class ApprovalServices: DaemonServices {
    let approvals: Approvals

    init(approvals: Approvals) { self.approvals = approvals }

    /// `answers.mode` is "Allow and accept edits", which `RemoteAnswers` offers on a Claude edit exactly as on the Mac.
    public var capabilities: Set<Capability> { [.answersMode] }

    public func snapshot(into parts: StateParts) async -> StateParts {
        var parts = parts
        parts.requests = await approvals.list()
        return parts
    }

    public func start(_ daemon: SideADaemon) async { await approvals.start(daemon) }
    public func stop() async { await approvals.stop() }

    public var routes: [DaemonRoute] {
        let approvals = approvals
        return [
            DaemonRoute("GET", "v1/requests") { context in
                // The sequence first: what the list holds is then at least as new as it says.
                let seq = await context.daemon.hub.seq
                return Wire.json(200, RequestList(requests: await approvals.list(), seq: seq))
            },
            DaemonRoute("GET", "v1/requests/{rid}") { context in
                guard let request = await approvals.request(context.params["rid"] ?? "") else { return .noRequest }
                return Wire.json(200, request)
            },
            DaemonRoute("POST", "v1/requests/{rid}/answer") { context in await approvals.answerRoute(context) },
        ]
    }
}

extension HTTPResponse {
    static var noRequest: HTTPResponse { .apiError(404, .requestNotFound, "That request isn't open on this computer any more.") }
}

extension Approvals {
    func answerRoute(_ context: RouteContext) async -> HTTPResponse {
        guard let body = context.body(AnswerBody.self) else { return .badJSON }
        let rid = context.params["rid"] ?? ""
        let subject: String?
        do {
            subject = try body.mode.map { try ConfirmMessage.subject(requestID: rid.lowercased(), allowMode: $0) }
                ?? ConfirmMessage.subject(requestID: rid.lowercased(), answer: body.answer)
        } catch { return .noRequest }
        // The daemon's own gate, judged now, decides what the phone must prove; the phone's confirmDestructive is ignored.
        var proven = ConfirmProof.none
        if let subject, let judged = needs(rid, body.answer, mode: body.mode), judged.needs > .none {
            if let refusal = await context.daemon.confirm(context.request, device: context.device, purpose: .allow, subject: subject, needs: judged.needs) {
                if let seen = shownGate(rid), ConfirmProof(seen) < judged.needs {
                    return .apiError(409, .gateChanged, "This request needs more now than when you saw it. Look again.", details: ["gate": judged.gate.rawValue])
                }
                return refusal
            }
            proven = judged.needs
        }
        let name = await context.daemon.devices.device(id: context.device)?.name ?? "iPhone"
        switch await answer(rid, body.answer, mode: body.mode, device: context.device, name: name, proven: proven) {
        case .done(let resolution): return Wire.json(200, resolution)
        case .unknown: return .noRequest
        case .conflict(let resolution):
            var details = ["by": resolution.by.rawValue]
            if let answer = resolution.answer { details["answer"] = answer.rawValue }
            if let name = resolution.deviceName { details["deviceName"] = name }
            return .apiError(409, .alreadyResolved, Self.alreadyResolved(resolution), details: details)
        case .refused(let reason):
            return .apiError(422, .invalidAnswer, Self.refusal(reason), details: ["reason": reason])
        }
    }

    static func alreadyResolved(_ resolution: RequestResolution) -> String {
        switch resolution.by {
        case .device: "This was already answered on \(resolution.deviceName ?? "another device")."
        case .terminal: "This was already answered in the terminal."
        case .handedBack: "This was handed back to the terminal."
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
}
