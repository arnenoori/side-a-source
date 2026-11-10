import Foundation
import Observation
import SideAProtocol

/// Where a session sits on the Sessions list, in Side A's order: what needs you first.
enum SessionPhase: Int, CaseIterable, Comparable {
    case needsYou, working, ready, idle

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .ready: "Ready"
        case .idle: "Idle"
        }
    }

    init(_ session: RemoteSession) {
        if !session.openRequests.isEmpty || session.status == .waiting { self = .needsYou }
        else if session.status == .working || session.status == .starting { self = .working }
        else if session.status == .finished { self = .ready }
        else { self = .idle }
    }
}

/// What the phone keeps per session beyond `RemoteSession`: when it started (for a fixed row
/// order) and the last reply (for the context menu preview).
struct SessionExtras: Hashable {
    var startedAt: Date
    var lastReply: String?
}

enum GroupBy: String, CaseIterable, Identifiable {
    case project, account, none
    var id: String { rawValue }
    var title: String { self == .none ? "None" : rawValue.capitalized }
}

@Observable
final class SessionsStore {
    nonisolated deinit {}

    private(set) var sessions: [RemoteSession]
    private(set) var extras: [SessionKey: SessionExtras]
    var groupBy: GroupBy = .project
    var showIdle = false

    /// `rows(_:)`'s answer for each phase, made once per change: the Sessions screen asks a dozen times a render.
    private var buckets: [SessionPhase: [RemoteSession]] = [:]

    init(_ sessions: [RemoteSession], extras: [SessionKey: SessionExtras] = [:]) {
        self.sessions = sessions; self.extras = extras
        rebucket()
    }

    func session(_ id: SessionKey) -> RemoteSession? { sessions.first { $0.id == id } }

    /// A new snapshot from the Mac. A session first seen now keeps that as its start, so the order
    /// within a phase never shifts under the user's thumb.
    func replace(_ sessions: [RemoteSession], finished: [SessionKey: FinishedSession], now: Date = .now) {
        var started = false
        for session in sessions where extras[session.id] == nil {
            extras[session.id] = SessionExtras(startedAt: session.statusAt.map { Date(timeIntervalSince1970: $0) } ?? now)
            started = true
        }
        for (id, done) in finished { extras[id]?.lastReply = done.summary }
        if self.sessions != sessions {
            self.sessions = sessions
            rebucket()
        } else if started {
            rebucket()
        }
    }

    /// Rows per phase. Within a phase the order is fixed (newest started first), so rows only move
    /// when their phase changes.
    func rows(_ phase: SessionPhase) -> [RemoteSession] { buckets[phase] ?? [] }

    private func rebucket() {
        let sorted = sessions.sorted { (extras[$0.id]?.startedAt ?? .distantPast) > (extras[$1.id]?.startedAt ?? .distantPast) }
        buckets = Dictionary(grouping: sorted, by: SessionPhase.init)
    }

    /// Rows of a phase under quiet subheaders, in order of first appearance.
    func groups(_ phase: SessionPhase) -> [(title: String?, rows: [RemoteSession])] {
        let rows = rows(phase)
        guard groupBy != .none else { return [(nil, rows)] }
        var order: [String] = []
        var byKey: [String: [RemoteSession]] = [:]
        for row in rows {
            let key = groupBy == .project ? row.project : (row.accountName ?? "No account")
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(row)
        }
        return order.map { ($0, byKey[$0]!) }
    }

    /// The demo's stand-in for the Mac leaving or clearing mail.
    func setMail(_ mail: MailState?, for id: SessionKey) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].mail = mail
        rebucket()
    }

    func resolve(_ request: RequestID, in id: SessionKey) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].openRequests.removeAll { $0 == request }
        if sessions[index].openRequests.isEmpty && sessions[index].status == .waiting {
            sessions[index].status = .working
            sessions[index].statusAt = Date.now.timeIntervalSince1970
        }
        rebucket()
    }
}

/// How the phone answered a request, for the folded line in the transcript.
enum RequestOutcome: Hashable {
    case allowed, denied, answered(String), approvedPlan(acceptEdits: Bool)
    /// Allowed, switching the session to this mode.
    case allowedSwitching(PermissionMode)
    /// Settled somewhere else: "Denied on Mac", "Answered in the terminal".
    case elsewhere(String)

    var isElsewhere: Bool { if case .elsewhere = self { true } else { false } }

    var line: String {
        switch self {
        case .allowed: "Allowed"
        case .denied: "Denied"
        case .answered(let summary): "Answered · \(summary)"
        case .elsewhere(let line): line
        case .approvedPlan(let acceptEdits): acceptEdits ? "Approved the plan · edits won't ask" : "Approved the plan"
        case .allowedSwitching(let mode): mode == .acceptEdits ? "Allowed · edits won't ask" : "Allowed · \(mode.title)"
        }
    }
}

@Observable
final class RequestsStore {
    nonisolated deinit {}

    private(set) var requests: [RequestID: RemoteRequest]
    /// Called once per answer, after the request leaves the open list.
    @ObservationIgnored var onResolve: ((RemoteRequest, RequestOutcome) -> Void)?
    /// Sends the answer to the Mac; nil in the demo.
    /// The answer, the mode an Allow switches to, and the `X-SideA-Confirm` already signed for it (Face ID's, from the
    /// approval sheet), if any.
    @ObservationIgnored var onAnswer: ((RemoteRequest, RemoteAnswer, PermissionMode?, String?) -> Void)?

    init(_ requests: [RemoteRequest]) {
        self.requests = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0) })
    }

    func request(_ id: RequestID) -> RemoteRequest? { requests[id] }

    /// The Mac's open requests, less those with an answer still in the outbox. One that leaves
    /// without an answer from this phone folds with what `settled` says happened to it; one the Mac
    /// gave no reason for (it restarted, say) just goes.
    func replace(_ open: [RequestID: RemoteRequest], settled: (RequestID) -> String? = { _ in nil }) {
        guard requests != open else { return }
        let gone = requests.values.filter { open[$0.id] == nil }.sorted { $0.arrivedAt < $1.arrivedAt }
        requests = open
        DeliveredRequests.clear(gone.map(\.id))
        for request in gone {
            if let line = settled(request.id) { onResolve?(request, .elsewhere(line)) }
        }
    }

    /// Open requests, oldest first.
    var open: [RemoteRequest] { requests.values.sorted { $0.arrivedAt < $1.arrivedAt } }

    /// Optimistic: the request leaves at once. The real outbox keeps it as "Sending…" until the
    /// Mac accepts, and turns a 409 into "Answered on Mac".
    /// `mode` goes with `.allow` only: Allow + Accept Edits.
    func answer(_ id: RequestID, _ answer: RemoteAnswer, mode: PermissionMode? = nil, confirm: String? = nil) {
        guard !DeviceKeys.appLocked, let request = requests.removeValue(forKey: id) else { return }
        DeliveredRequests.clear([id])
        onAnswer?(request, answer, mode, confirm)
        let outcome: RequestOutcome = switch answer {
        case .allow where mode != nil: .allowedSwitching(mode!)
        case .allow, .always: .allowed
        case .approvePlan(let acceptEdits): .approvedPlan(acceptEdits: acceptEdits)
        case .deny, .terminal: .denied
        case .answers(let answers): .answered(answers.flatMap { $0.picked.map(IslandQuestion.Option.titleOf) + ($0.other.map { [$0] } ?? []) }
            .joined(separator: ", "))
        }
        onResolve?(request, outcome)
    }
}

extension IslandQuestion.Option {
    /// The label without "(Recommended)".
    static func titleOf(_ label: String) -> String { IslandQuestion.Option(label: label, description: nil).title }
}

/// A transcript as the phone draws it: the Mac's messages plus what the phone answered.
@Observable
final class TranscriptStore {
    nonisolated deinit {}

    private(set) var messages: [SessionKey: [TranscriptMessage]]
    /// Messages before the loaded page, for the "18 earlier messages" fold.
    private(set) var earlier: [SessionKey: Int]
    private(set) var answered: [SessionKey: [AnsweredRequest]] = [:]

    struct AnsweredRequest: Hashable, Identifiable {
        let request: RemoteRequest
        let outcome: RequestOutcome
        var delivery: Delivery = .delivered
        var id: RequestID { request.id }
    }

    /// Where the answer is on its way to the Mac. The demo's are delivered at once.
    enum Delivery: Hashable {
        case sending, delivered, answeredElsewhere
        /// 409 `outcome_unknown`: it may or may not have reached the Mac; Retry sends it again.
        case unknown
        /// A retry found the request gone: the first attempt may have landed, or the turn moved on.
        case gone
        /// The Mac refused it or never heard it; the request is open again.
        case failed(String)
    }

    /// Messages the Mac cut at 6,000 characters (`textTruncated`), fetched whole, by session and seq. One counts only
    /// while the same entry (uuid) holds that seq.
    private(set) var whole: [SessionKey: [Int: TranscriptMessage]] = [:]
    /// Cut messages on their way, or that wouldn't load, by "session:seq".
    private(set) var wholeLoads: [String: WholeLoad] = [:]

    enum WholeLoad: Hashable { case loading, failed }

    /// Live: page earlier messages in, and send an answer again. Nil in the demo.
    @ObservationIgnored var onLoadEarlier: ((SessionKey) -> Void)?
    /// `GET …/messages/{seq}`; nil where nothing can fetch it.
    @ObservationIgnored var onLoadWhole: ((SessionKey, Int) async throws -> TranscriptMessage)?
    @ObservationIgnored var onRetry: ((AnsweredRequest) -> Void)?

    init(_ messages: [SessionKey: [TranscriptMessage]], earlier: [SessionKey: Int] = [:]) {
        self.messages = messages; self.earlier = earlier
    }

    /// A transcript window from the Mac. Sequence numbers start at 0, so the first loaded message's
    /// `seq` counts what's earlier. A sent turn the Mac now shows leaves `outgoing`.
    func set(_ list: [TranscriptMessage], hasEarlier: Bool, for session: SessionKey) {
        if messages[session] != list { messages[session] = list }
        let count = hasEarlier ? max(list.first?.seq ?? 1, 1) : 0
        if earlier[session] != count { earlier[session] = count }
        settleOutgoing(session)
    }

    func record(_ outcome: RequestOutcome, for request: RemoteRequest, in session: SessionKey) {
        let delivery: Delivery = onRetry == nil || outcome.isElsewhere ? .delivered : .sending
        let row = AnsweredRequest(request: request, outcome: outcome, delivery: delivery)
        // A request has one line: answering it again after a refusal, or its settling elsewhere, updates that line.
        if let index = answered[session]?.firstIndex(where: { $0.id == request.id }) {
            answered[session]?[index] = row
        } else {
            answered[session, default: []].append(row)
        }
    }

    func deliver(_ request: RequestID, in session: SessionKey, _ delivery: Delivery) {
        guard let index = answered[session]?.firstIndex(where: { $0.id == request }),
              answered[session]?[index].delivery != delivery else { return }
        answered[session]?[index].delivery = delivery
    }

    /// The message's text, whole once it's been fetched.
    func text(_ message: TranscriptMessage, in session: SessionKey) -> String? {
        guard message.textTruncated, let full = whole[session]?[message.seq], full.uuid == message.uuid else { return message.text }
        return full.text
    }

    /// The loaded messages, each cut one whole where it's been fetched.
    func wholeMessages(_ session: SessionKey) -> [TranscriptMessage] {
        (messages[session] ?? []).map { message in
            whole[session]?[message.seq].flatMap { $0.uuid == message.uuid ? $0 : nil } ?? message
        }
    }

    /// Cut by the Mac and not fetched yet.
    func isCut(_ message: TranscriptMessage, in session: SessionKey) -> Bool {
        message.textTruncated && whole[session]?[message.seq]?.uuid != message.uuid
    }

    func wholeLoad(_ message: TranscriptMessage, in session: SessionKey) -> WholeLoad? { wholeLoads["\(session):\(message.seq)"] }

    /// Fetches the rest of a cut message once, whether or not its row stays on screen; a failure waits for Try Again.
    func loadWhole(_ message: TranscriptMessage, in session: SessionKey, again: Bool = false) {
        let key = "\(session):\(message.seq)"
        guard isCut(message, in: session), let onLoadWhole, wholeLoads[key] == nil || (again && wholeLoads[key] == .failed) else { return }
        wholeLoads[key] = .loading
        Task { @MainActor in
            do {
                let full = try await onLoadWhole(session, message.seq)
                // Another entry at that seq (a new generation), or still cut: nothing whole to show.
                guard full.uuid == message.uuid, !full.textTruncated else { throw URLError(.cannotParseResponse) }
                whole[session, default: [:]][message.seq] = full
                wholeLoads[key] = nil
            } catch {
                wholeLoads[key] = .failed
            }
        }
    }

    func loadEarlier(_ session: SessionKey) {
        if let onLoadEarlier { onLoadEarlier(session) } else { earlier[session] = 0 }
    }

    // MARK: Outgoing

    /// A turn this phone sent that the Mac's transcript doesn't show yet. A note never shows there
    /// (the session reads it through a hook), so it stays as the phone's own record.
    struct Outgoing: Hashable, Identifiable {
        let id: String
        var text: String
        let at: Date
        var state: State

        enum State: Hashable {
            case sending
            /// Accepted; waits for the Mac's copy of the turn.
            case sent
            /// Waits for the turn to end: a hosted session's queue, or Codex's own (`submit: .queue`).
            case queued
            /// Left as mail: the session reads it after its current step, and Take Back works until then.
            case note
            case takingBack
            /// The session took the note.
            case read
        }

        var isPendingNote: Bool { state == .note || state == .takingBack }
    }

    /// A reply the Mac didn't take: its text goes back into the field with "Not sent · Retry" under it.
    struct Unsent: Hashable {
        let text: String
        let reason: String
        /// The reply's flight, by its outbox item, for a Retry with what it carried; nil sends the text fresh.
        let item: String?
    }

    private(set) var outgoing: [SessionKey: [Outgoing]] = [:]
    private(set) var unsent: [SessionKey: Unsent] = [:]
    /// What's typed in each session's composer, kept across visits; a failed reply or a taken-back note returns here.
    var drafts: [SessionKey: String] = [:]
    /// A steer the Mac refused ("Couldn't stop it"), shown under the field until the next one.
    private(set) var notices: [SessionKey: String] = [:]

    func notice(_ text: String?, in session: SessionKey) { if notices[session] != text { notices[session] = text } }

    /// Shows the turn at once; the link (or the demo) moves its state along.
    @discardableResult func send(_ text: String, to session: SessionKey, at: Date = .now) -> Outgoing {
        unsent[session] = nil
        let turn = Outgoing(id: UUID().uuidString.lowercased(), text: text, at: at, state: .sending)
        outgoing[session, default: []].append(turn)
        return turn
    }

    func mark(_ id: String, in session: SessionKey, _ state: Outgoing.State) {
        guard let index = outgoing[session]?.firstIndex(where: { $0.id == id }), outgoing[session]?[index].state != state else { return }
        outgoing[session]?[index].state = state
        if state == .sent || state == .queued { settleOutgoing(session) }
    }

    /// The Mac didn't take it: the turn goes, its text waits in the field. False when the turn is already gone.
    /// The Mac gave up on what it was holding for this session.
    func failQueued(in session: SessionKey, reason: String) {
        let lost = outgoing[session]?.filter { $0.state == .queued } ?? []
        outgoing[session]?.removeAll { $0.state == .queued }
        giveBack(lost.map(\.text), in: session, reason: reason)
    }

    /// What the Mac still remembers giving up on, against what this phone has already settled; answers the new settled set.
    /// The phone that sent a reply gets it back even with no turn left to show for it, as after a relaunch. Another phone's
    /// comes with no words and is only noted. One from an old queue file gives back this phone's own turns from before it.
    func settle(_ dropped: [DroppedReply], device: String, settled: Set<String>) -> Set<String> {
        let fresh = dropped.filter { !settled.contains($0.id) }.sorted { $0.at < $1.at }
        for (session, records) in Dictionary(grouping: fresh, by: \.sessionID) {
            var lost: [String] = []
            for record in records {
                if record.reason == .oldQueue {
                    let held = outgoing[session]?.filter { $0.state == .queued && $0.at.timeIntervalSince1970 <= record.at } ?? []
                    outgoing[session]?.removeAll { turn in held.contains { $0.id == turn.id } }
                    lost += held.map(\.text)
                } else if record.device == device, let text = record.text {
                    let turn = outgoing[session]?.first { $0.state == .queued && $0.text == text && $0.at.timeIntervalSince1970 <= record.at }
                    if let turn { outgoing[session]?.removeAll { $0.id == turn.id } }
                    lost.append(text)
                }
            }
            giveBack(lost, in: session, reason: records[0].reason.unsentReason)
        }
        return settled.intersection(dropped.map(\.id)).union(fresh.map(\.id))
    }

    private func giveBack(_ texts: [String], in session: SessionKey, reason: String) {
        guard !texts.isEmpty else { return }
        let text = texts.joined(separator: "\n\n")
        unsent[session] = Unsent(text: text, reason: reason, item: nil)
        restore(text, in: session)
    }

    @discardableResult func fail(_ id: String, in session: SessionKey, reason: String, item: String?) -> Bool {
        guard let turn = outgoing[session]?.first(where: { $0.id == id }) else { return false }
        outgoing[session]?.removeAll { $0.id == id }
        unsent[session] = Unsent(text: turn.text, reason: reason, item: item)
        restore(turn.text, in: session)
        return true
    }

    /// A turn the outbox still holds from before this launch: back as it was.
    func adopt(_ id: String, text: String, at: Date, to session: SessionKey) {
        guard outgoing[session]?.contains(where: { $0.id == id }) != true else { return }
        outgoing[session, default: []].append(Outgoing(id: id, text: text, at: at, state: .sending))
    }

    /// Text back into the field, unless something new is being typed there.
    private func restore(_ text: String, in session: SessionKey) {
        if drafts[session, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { drafts[session] = text }
    }

    func clearUnsent(_ session: SessionKey) { unsent[session] = nil }

    /// Take Back landed: the note leaves the transcript and returns the text it carried.
    @discardableResult func withdraw(_ id: String, in session: SessionKey, restoring: Bool = true) -> String? {
        guard let turn = outgoing[session]?.first(where: { $0.id == id }) else { return nil }
        outgoing[session]?.removeAll { $0.id == id }
        if restoring { restore(turn.text, in: session) }
        return turn.text
    }

    /// An Edit that came too late: the session already read the note, so its text waits in the field as a new message.
    func editTooLate(_ id: String, in session: SessionKey) {
        guard let turn = outgoing[session]?.first(where: { $0.id == id }) else { return }
        restore(turn.text, in: session)
        notice("Already sent. Your text is in the field as a new message.", in: session)
    }

    /// The note this phone left that the session hasn't read yet.
    func pendingNote(_ session: SessionKey) -> Outgoing? { outgoing[session]?.last(where: \.isPendingNote) }

    /// A second note while one waits replaces it on the Mac (one mail slot per session), so the two
    /// travel as one: the waiting turn takes the new text and goes back to sending.
    func merge(_ text: String, into id: String, in session: SessionKey) -> String? {
        guard let index = outgoing[session]?.firstIndex(where: { $0.id == id }) else { return nil }
        outgoing[session]?[index].text += "\n\n" + text
        outgoing[session]?[index].state = .sending
        return outgoing[session]?[index].text
    }

    /// The session's mail emptied without a Take Back from here: it read the note.
    func noteRead(in session: SessionKey) {
        for index in outgoing[session]?.indices ?? 0..<0 where outgoing[session]?[index].state == .note {
            outgoing[session]?[index].state = .read
        }
    }

    /// A sent turn goes once the Mac's transcript has a user turn with its text from about then on.
    private func settleOutgoing(_ session: SessionKey) {
        guard let turns = outgoing[session], turns.contains(where: { $0.state == .sent || $0.state == .queued }) else { return }
        let users = (messages[session] ?? []).filter { $0.role == .user }
        let shown = turns.filter { turn in
            (turn.state == .sent || turn.state == .queued) && users.contains { user in
                user.text?.trimmingCharacters(in: .whitespacesAndNewlines) == turn.text
                    && (user.at ?? .infinity) >= turn.at.timeIntervalSince1970 - 30
            }
        }
        guard !shown.isEmpty else { return }
        outgoing[session]?.removeAll { shown.contains($0) }
    }
}

@Observable
final class AccountsStore {
    nonisolated deinit {}

    private(set) var accounts: [RemoteAccount]
    private(set) var autopilot: [AutopilotDecision]

    init(_ accounts: [RemoteAccount], autopilot: [AutopilotDecision] = []) {
        self.accounts = accounts; self.autopilot = autopilot
    }

    func replace(_ accounts: [RemoteAccount]) {
        let sorted = accounts.sorted { ($0.active ? 0 : 1, $0.name) < ($1.active ? 0 : 1, $1.name) }
        if self.accounts != sorted { self.accounts = sorted }
    }

    var inUse: RemoteAccount? { accounts.first { $0.active && $0.provider == .claude } ?? accounts.first { $0.active } }

    /// The newest reading, for "Updated 2 min ago".
    var updated: Date? { accounts.compactMap(\.readAt).max().map(Date.init(timeIntervalSince1970:)) }

    /// The window closest to its limit, of the account in use.
    func tightest(_ account: RemoteAccount, now: Date = .now) -> UsageWindow? {
        account.usage?.windows.max { $0.used(at: now.timeIntervalSince1970) < $1.used(at: now.timeIntervalSince1970) }
    }
}

@Observable
final class HistoryStore {
    nonisolated deinit {}

    private(set) var past: [PastSession]
    var pinned: Set<String> = []

    /// Newest first.
    init(_ past: [PastSession]) { self.past = past.sorted { ($0.lastAt ?? 0) > ($1.lastAt ?? 0) } }

    func search(_ query: String) -> [PastSession] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return past }
        return past.filter { [$0.title, $0.project, $0.snippet ?? ""].contains { $0.localizedCaseInsensitiveContains(query) } }
    }
}

extension DroppedReply.Reason {
    /// Under the field, with the text back in it.
    var unsentReason: String {
        switch self {
        case .cannotWait: "This session couldn't take it when its turn ended."
        case .outranked: "This session needs Face ID for it now."
        case .oldQueue: "Side A updated before it could be sent."
        default: "This session ended before it could be sent."
        }
    }
}
