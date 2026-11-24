import Foundation
import Observation
import SideAProtocol
import SideARemoteKit

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

struct SessionExtras: Hashable {
    var startedAt: Date
    var lastReply: String?
}

enum GroupBy: String, CaseIterable, Identifiable, Codable {
    case project, account, none
    var id: String { rawValue }
    var title: String { self == .none ? "None" : rawValue.capitalized }
}

@Observable
final class SessionsStore {
    nonisolated deinit {}

    private(set) var sessions: [RemoteSession]
    private(set) var extras: [SessionKey: SessionExtras]
    var prefs: ListPrefs { didSet { if prefs != oldValue { ListPrefsStore.save(prefs, mac: macID, in: defaults) } } }
    var groupBy: GroupBy { get { prefs.groupBy } set { prefs.groupBy = newValue } }
    var sortBy: SortBy { get { prefs.sortBy } set { prefs.sortBy = newValue } }
    var idleExpanded: Bool { get { prefs.idleExpanded } set { prefs.idleExpanded = newValue } }
    @ObservationIgnored var title: (RemoteSession) -> String = \.title

    @ObservationIgnored private let macID: String
    @ObservationIgnored private let defaults: UserDefaults

    private var buckets: [SessionPhase: [RemoteSession]] = [:]

    init(_ sessions: [RemoteSession], extras: [SessionKey: SessionExtras] = [:], macID: String = "", defaults: UserDefaults = .standard) {
        self.sessions = sessions; self.extras = extras; self.macID = macID; self.defaults = defaults
        prefs = ListPrefsStore.load(mac: macID, in: defaults)
        rebucket()
    }

    func session(_ id: SessionKey) -> RemoteSession? { sessions.first { $0.id == id } }

    func setQueued(_ queued: [QueuedReply], for id: SessionKey) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].queued = queued.isEmpty ? nil : queued
    }

    func replace(_ sessions: [RemoteSession], finished: [SessionKey: FinishedSession], now: Date = .now) {
        var started = false
        for session in sessions where extras[session.id] == nil {
            extras[session.id] = SessionExtras(startedAt: session.statusAt.map { Date(timeIntervalSince1970: $0) } ?? now)
            started = true
        }
        for (id, done) in finished { extras[id]?.lastReply = done.summary }
        if self.sessions != sessions {
            if !leaving.isEmpty { leaving.formIntersection(sessions.map(\.id)) }
            self.sessions = sessions
            rebucket()
        } else if started {
            rebucket()
        }
    }

    /// Rows per phase. Within a phase the order is fixed (newest started first), so rows only move
    /// when their phase changes.
    func rows(_ phase: SessionPhase) -> [RemoteSession] {
        leaving.isEmpty ? buckets[phase] ?? [] : (buckets[phase] ?? []).filter { !leaving.contains($0.id) }
    }

    /// Sessions swiped away whose quit still waits out its Undo.
    private(set) var leaving: Set<SessionKey> = []

    func setLeaving(_ id: SessionKey, _ leaving: Bool) {
        if leaving { self.leaving.insert(id) } else { self.leaving.remove(id) }
    }

    private func rebucket() {
        let sorted = sessions.sorted { (extras[$0.id]?.startedAt ?? .distantPast) > (extras[$1.id]?.startedAt ?? .distantPast) }
        buckets = Dictionary(grouping: sorted, by: SessionPhase.init)
    }

    func sorted(_ rows: [RemoteSession]) -> [RemoteSession] {
        let key: (RemoteSession) -> (String, String)
        switch sortBy {
        case .newest: return rows
        case .name: key = { (self.title($0), "") }
        case .project: key = { ($0.project, self.title($0)) }
        }
        return rows.enumerated().map { (key: key($1), index: $0, row: $1) }.sorted { a, b in
            let first = a.key.0.localizedStandardCompare(b.key.0)
            if first != .orderedSame { return first == .orderedAscending }
            let second = a.key.1.localizedStandardCompare(b.key.1)
            return second == .orderedSame ? a.index < b.index : second == .orderedAscending
        }.map(\.row)
    }

    func groups(_ phase: SessionPhase, where include: (RemoteSession) -> Bool = { _ in true }) -> [(title: String?, rows: [RemoteSession])] {
        let rows = sorted(rows(phase).filter(include))
        guard groupBy != .none else { return [(nil, rows)] }
        var order: [String] = []
        var byKey: [String: [RemoteSession]] = [:]
        for row in rows {
            let key = groupBy == .project ? row.project : (row.accountName ?? "No account")
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(row)
        }
        if sortBy != .newest { order.sort { $0.localizedStandardCompare($1) == .orderedAscending } }
        return order.map { ($0, byKey[$0]!) }
    }

    func matches(_ session: RemoteSession, _ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let fields = [title(session), session.title, session.project, session.branch, session.accountName, session.model].compactMap { $0 }
        return words.allSatisfy { word in fields.contains { $0.localizedStandardContains(word) } }
    }

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

enum RequestOutcome: Hashable {
    case allowed, denied, answered(String), approvedPlan(acceptEdits: Bool)
    case allowedSwitching(PermissionMode)
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

    var open: [RemoteRequest] { requests.values.sorted { $0.arrivedAt < $1.arrivedAt } }

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
    static func titleOf(_ label: String) -> String { IslandQuestion.Option(label: label, description: nil).title }
}

@Observable
final class TranscriptStore {
    nonisolated deinit {}

    private(set) var messages: [SessionKey: [TranscriptMessage]]
    private(set) var earlier: [SessionKey: Int]
    private(set) var answered: [SessionKey: [AnsweredRequest]] = [:]

    struct AnsweredRequest: Hashable, Identifiable {
        let request: RemoteRequest
        let outcome: RequestOutcome
        var delivery: Delivery = .delivered
        var id: RequestID { request.id }
    }

    enum Delivery: Hashable {
        case sending, delivered, answeredElsewhere
        /// 409 `outcome_unknown`: it may or may not have reached the Mac; Retry sends it again.
        case unknown
        case gone
        case failed(String)
    }

    /// Messages the Mac cut at 6,000 characters (`textTruncated`), fetched whole, by session and seq. One counts only
    /// while the same entry (uuid) holds that seq.
    private(set) var whole: [SessionKey: [Int: TranscriptMessage]] = [:]
    private(set) var wholeLoads: [String: WholeLoad] = [:]

    enum WholeLoad: Hashable { case loading, failed }

    private(set) var loadFailures: Set<SessionKey> = []

    func loadFailed(_ failed: Bool, for session: SessionKey) {
        if failed { loadFailures.insert(session) } else { loadFailures.remove(session) }
    }

    @ObservationIgnored var onLoadEarlier: ((SessionKey) -> Void)?
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

    func text(_ message: TranscriptMessage, in session: SessionKey) -> String? {
        guard message.textTruncated, let full = whole[session]?[message.seq], full.uuid == message.uuid else { return message.text }
        return full.text
    }

    func text(_ end: TurnEnd, in session: SessionKey) -> String { text(end.message, in: session) ?? "" }

    func wholeMessages(_ session: SessionKey) -> [TranscriptMessage] {
        (messages[session] ?? []).map { message in
            whole[session]?[message.seq].flatMap { $0.uuid == message.uuid ? $0 : nil } ?? message
        }
    }

    func isCut(_ message: TranscriptMessage, in session: SessionKey) -> Bool {
        message.textTruncated && whole[session]?[message.seq]?.uuid != message.uuid
    }

    func wholeLoad(_ message: TranscriptMessage, in session: SessionKey) -> WholeLoad? { wholeLoads["\(session):\(message.seq)"] }

    func loadWhole(_ message: TranscriptMessage, in session: SessionKey, again: Bool = false) {
        let key = "\(session):\(message.seq)"
        guard isCut(message, in: session), let onLoadWhole, wholeLoads[key] == nil || (again && wholeLoads[key] == .failed) else { return }
        wholeLoads[key] = .loading
        Task { @MainActor in
            do {
                let full = try await onLoadWhole(session, message.seq)
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

    var outgoing: [SessionKey: [Outgoing]] = [:]
    var unsent: [SessionKey: Unsent] = [:]
    var drafts: [SessionKey: String] = [:] {
        didSet { if drafts != oldValue { onDraftsChanged?() } }
    }
    @ObservationIgnored var onDraftsChanged: (() -> Void)?
    var notices: [SessionKey: String] = [:]
    @ObservationIgnored var photosBack: ((_ photos: [(turn: String, ids: [String])], _ session: SessionKey) -> Void)?
    var firstPrompts: [String: Outgoing] = [:]
    var carried: [String: SessionKey] = [:]
    var waitingReplies: [String: Outgoing] = [:]
    @ObservationIgnored var shownAway: [SessionKey: [Outgoing]] = [:]
    /// User turns that already settled one, by uuid: one user turn is one message, so two "yes" need two. The transcript's
    /// rather than a bubble's, since it outlives the bubble it settled.
    @ObservationIgnored var settledBy: [SessionKey: Set<String>] = [:]
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

    var updated: Date? { accounts.compactMap(\.readAt).max().map(Date.init(timeIntervalSince1970:)) }

    func tightest(_ account: RemoteAccount, now: Date = .now) -> UsageWindow? {
        account.usage?.windows.max { $0.used(at: now.timeIntervalSince1970) < $1.used(at: now.timeIntervalSince1970) }
    }
}

@Observable
final class HistoryStore {
    nonisolated deinit {}

    private(set) var past: [PastSession]
    var pinned: Set<String> = []

    init(_ past: [PastSession]) { self.past = past.sorted { ($0.lastAt ?? 0) > ($1.lastAt ?? 0) } }

    func search(_ query: String) -> [PastSession] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return past }
        return past.filter { [$0.title, $0.project, $0.snippet ?? ""].contains { $0.localizedCaseInsensitiveContains(query) } }
    }
}

extension DroppedReply.Reason {
    var unsentReason: String {
        switch self {
        case .cannotWait: "This session couldn't take it when its turn ended."
        case .outranked: "This session needs Face ID for it now."
        case .oldQueue: "Side A updated before it could be sent."
        default: "This session ended before it could be sent."
        }
    }
}
