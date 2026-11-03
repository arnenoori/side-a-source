import Foundation
import SideACore

/// Answering, replying and queueing from the phone. The rules are the island's own; the phone never sends tool input.
extension Island {
    enum RemoteOutcome: Sendable, Equatable {
        case done(RequestResolution)
        /// 409 `already_resolved`, with who settled it first.
        case conflict(RequestResolution)
        /// 404 `request_not_found`.
        case unknown
        /// 422 `invalid_answer` with this `details.reason`.
        case refused(String)
    }

    /// What answering a pending request this way must prove, by the gate it has now.
    func remoteNeeds(_ rid: String, _ answer: RemoteAnswer, mode: PermissionMode?) -> (gate: AllowGate, needs: ConfirmProof)? {
        guard let id = UUID(uuidString: rid), let item = pending.first(where: { $0.id == id }) else { return nil }
        let gate = AllowGate.of(item.request, projects: Self.projects(item.request.cwd))
        return (gate, RemoteAnswers.needs(item.request, answer, mode: mode, gate: gate))
    }

    /// `proven` is what the phone's confirm signature showed, already checked by the route.
    func remoteAnswer(_ rid: String, _ wire: RemoteAnswer, mode: PermissionMode? = nil, device: String, name: String, proven: ConfirmProof) -> RemoteOutcome {
        guard let id = UUID(uuidString: rid) else { return .unknown }
        guard let item = pending.first(where: { $0.id == id }) else {
            guard let settled = resolved[id] else { return .unknown }
            return .conflict(Self.resolution(id, settled.by, settled.answer, at: settled.at))
        }
        let gate = AllowGate.of(item.request, projects: Self.projects(item.request.cwd))
        switch RemoteAnswers.resolve(item.request, wire, mode: mode, gate: gate, proven: proven) {
        case .failure(let refusal): return .refused(refusal.rawValue)
        case .success(let (answer, confirmed)):
            let by = Resolution.remote(device: device, name: name)
            guard respond(answer, id, quietly: true, confirmed: confirmed, by: by) else { return .refused(RemoteAnswers.Refusal.needsConfirm.rawValue) }
            return .done(Self.resolution(id, by, answer, at: Date()))
        }
    }

    /// Whether keys typed into this session could answer one of its requests. Keys always take Face ID (`ConfirmPolicy`);
    /// a destructive request refuses them outright, since keys would bypass its confirmation.
    func remoteKeysGuard(conversation: String?, pid: Int?) -> (pending: Bool, destructive: Bool) {
        let mine = pending.filter { $0.request.sessionID.map { $0 == conversation } ?? ($0.request.pid == pid) }
        return (!mine.isEmpty, mine.contains { AllowGate.of($0.request, projects: Self.projects($0.request.cwd)) == .biometric })
    }

    enum FollowUp: Sendable, Equatable { case sent, noWaiter, turnChanged }

    /// The waiter path of `reply` only: the Mac's clipboard fallback means nothing to a phone.
    func remoteFollowUp(session: String, turnID: String?, text: String) -> FollowUp {
        guard let row = ready.first(where: { $0.finish.sessionID == session }), canReply(row) else { return .noWaiter }
        if let turnID, turnID.lowercased() != row.id.uuidString.lowercased() { return .turnChanged }
        reply(row, text)
        return .sent
    }

    func hasWaiter(_ session: String) -> Bool { ready.contains { $0.finish.sessionID == session && $0.waiter != nil } }

    static func resolution(_ id: UUID, _ by: Resolution, _ answer: IslandAnswer?, at: Date) -> RequestResolution {
        let wireBy: RequestResolution.By
        var deviceID: String?, deviceName: String?
        switch by {
        case .mac, .notification: wireBy = .mac
        case .remote(let device, let name): wireBy = .device; deviceID = device; deviceName = name
        case .terminal: wireBy = .terminal
        case .finished: wireBy = .turnFinished
        case .handedBack: wireBy = .handedBack
        case .gone: wireBy = .sessionEnded
        case .auto: wireBy = .autoAnswered
        }
        // Only a person's answer, or the recommended one given for them, has a kind; the island's own hand-backs don't.
        let person: Bool
        switch by { case .mac, .notification, .remote, .auto: person = true; default: person = false }
        return RequestResolution(requestID: id.uuidString.lowercased(), by: wireBy, deviceID: deviceID, deviceName: deviceName,
                                 answer: person ? answer.map(Self.kind) : nil, at: at.timeIntervalSince1970)
    }

    static func kind(_ answer: IslandAnswer) -> AnswerKind {
        switch answer {
        // The protocol lists allowMode on a request but records the answer as the allow it is.
        case .allow, .allowMode: .allow
        case .always: .always
        case .deny: .deny
        case .terminal: .terminal
        case .answers: .answers
        case .approvePlan: .approvePlan
        }
    }

    /// The session's folder and its git root: what "inside the project" means for the lock-screen allowlist.
    static func projects(_ cwd: String?) -> [String] {
        guard let cwd, !cwd.isEmpty else { return [] }
        var url = URL(fileURLWithPath: cwd).standardizedFileURL
        var roots = [url.path]
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                if url.path != cwd { roots.append(url.path) }
                break
            }
            url.deleteLastPathComponent()
        }
        return roots
    }
}

/// The gate each request was last sent to a phone with, so an answer signed for a lower one gets 409 `gate_changed`
/// rather than a bare confirm_required.
final class ShownGates: @unchecked Sendable {
    static let shared = ShownGates()
    private let lock = NSLock()
    private var gates: [UUID: AllowGate] = [:]

    subscript(id: UUID) -> AllowGate? {
        get { lock.withLock { gates[id] } }
        set { lock.withLock { if gates.count > 512 { gates.removeAll() }; gates[id] = newValue } }
    }
}
