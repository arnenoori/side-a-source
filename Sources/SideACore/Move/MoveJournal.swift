import Foundation

/// What each computer has written down about the moves it takes part in (docs/moving-sessions-prd.md, 4.6).
///
/// A move is a hand-over in two phases. The source stops the session, sends it, and waits for the destination to
/// say it holds a verified copy that is not running. Only then does the source ask the destination to start it.
/// The rule both sides keep: the source starts the conversation again only on the destination's word that it did
/// not start, and the destination starts it only when asked, once, and never after it was told to drop it. A
/// reply that never arrives leaves the source in `unknown`, which it shows as unknown and settles by asking.
public struct MoveJournal: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case source, destination }

    public enum Step: String, Codable, Sendable {
        // The source's side.
        /// Checked and agreed; the session is still running here.
        case prepared
        /// Stopped here, files captured. Nothing asked of the destination that it cannot forget.
        case held
        /// The destination holds a verified copy and has not started it.
        case sent
        /// Asked to start. Until the answer arrives the session may be running there.
        case committing
        /// Running on the other computer.
        case away
        /// Back here: the move was undone, or the session was brought back.
        case returned
        /// Asked to start and heard nothing. Running there or not; only the destination knows.
        case unknown
        // The destination's side.
        /// Receiving files.
        case staging
        /// Holding a verified copy, not running.
        case staged
        /// Asked to start and starting: not yet known to run. The sender waits and never restarts on this.
        case starting
        /// Started here.
        case live
        /// Ran here and then left for another computer. Still "it started" to the computer that sent it.
        case gone
        /// Dropped, and never to be started under this move.
        case discarded
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let id: String
        public let role: Role
        public let session: String
        public let agent: String
        /// The other computer's host id and the name shown for it.
        public let peer: String
        public let peerName: String
        public var step: Step
        public let startedAt: Double
        public var updatedAt: Double
        /// Source: the folder the session ran in. Destination: the folder it landed in, once it has.
        public var folder: String?
        /// The hosted session's name on this computer.
        public var name: String?
        /// The account whose login went with the session, when one did.
        public var login: String?
        /// What the session was called and the repository it worked in, for lists of moved sessions.
        public var title: String?
        public var project: String?
        /// Source: the hosted session it runs in on the other computer.
        public var remote: String?
        /// Source: how the session ran here, so a move that is undone, even after a relaunch, starts it the same way.
        public var restart: Restart?
        /// Source: the move it arrived here under, when its agent had exited before it left. Nothing was stopped for
        /// the move, so undoing it starts nothing.
        public var ended: String?

        public init(id: String, role: Role, session: String, agent: String, peer: String, peerName: String, step: Step,
                    at: Double, folder: String? = nil, name: String? = nil, login: String? = nil) {
            self.id = id; self.role = role; self.session = session; self.agent = agent; self.peer = peer
            self.peerName = peerName; self.step = step; self.startedAt = at; self.updatedAt = at
            self.folder = folder; self.name = name; self.login = login
        }
    }

    /// The account and options a source session ran with on this computer, read from it before it was stopped.
    public struct Restart: Codable, Equatable, Sendable {
        /// The `sidea use` pin of a Claude session, and the account of a Codex one.
        public var pin: String?
        public var codexAccount: String?
        public var model: String?
        public var effort: String?
        /// The protocol's PermissionMode, as the session ran here. Never one the other computer chose.
        public var permissionMode: String?

        public init(pin: String? = nil, codexAccount: String? = nil, model: String? = nil, effort: String? = nil, permissionMode: String? = nil) {
            self.pin = pin; self.codexAccount = codexAccount; self.model = model; self.effort = effort; self.permissionMode = permissionMode
        }
    }

    /// Where a conversation is, as this computer knows it.
    public enum Ownership: Equatable, Sendable {
        case here
        /// Being sent; stopped here and not started there.
        case leaving(peer: String)
        case arriving(peer: String)
        case away(peer: String)
        case unknown(peer: String)

        /// Whether this computer may start, resume or type into the conversation.
        public var mayRun: Bool { self == .here }
    }

    /// What the destination answers when asked about a move.
    public enum PeerStatus: String, Codable, Sendable {
        /// Never heard of it, and has now written down that it must not start.
        case none
        case staging, staged, starting, live, discarded
    }

    /// What the source does after its app restarts or a reply is lost.
    public enum Recovery: Equatable, Sendable {
        /// Nothing was asked that could have started the session there: start it here again and tell the destination to drop it.
        case rollBack
        /// Ask the destination what it did.
        case ask
        case nothing
    }

    public enum Verdict: Equatable, Sendable {
        case start
        /// Already started under this move; the first answer was lost. Not started again.
        case alreadyLive
        /// Asked before and still starting: the caller waits and asks again.
        case starting
        case refused
    }

    /// A staged copy nobody asked to start is dropped after this long; the source has rolled back by then.
    public static let stagedFor = 3600.0
    /// Finished entries are kept this long so a late or repeated request still gets the same answer.
    public static let remembered = 30 * 86_400.0

    private var entries: [String: Entry] = [:]

    public init() {}

    public subscript(id: String) -> Entry? { entries[id] }
    public var all: [Entry] { entries.values.sorted { $0.startedAt < $1.startedAt } }

    // MARK: Source

    public mutating func begin(_ entry: Entry) {
        entries[entry.id] = entry
    }

    /// Moves a source entry forward. A step that does not follow from the current one is ignored and reported.
    @discardableResult
    public mutating func advance(_ id: String, to step: Step, at: Double) -> Bool {
        guard var entry = entries[id], Self.follows[entry.step, default: []].contains(step) else { return false }
        entry.step = step
        entry.updatedAt = at
        entries[id] = entry
        return true
    }

    private static let follows: [Step: Set<Step>] = [
        .prepared: [.held, .returned],
        .held: [.sent, .returned],
        .sent: [.committing, .returned],
        .committing: [.away, .returned, .unknown],
        .unknown: [.away, .returned],
        .away: [.returned],
        .staging: [.staged, .discarded],
        .staged: [.starting, .discarded],
        .starting: [.live, .discarded],
        .live: [.gone],
    ]

    /// Writes down that an account's login is going with this move, before it is sent.
    public mutating func carry(_ id: String, login: String?) {
        entries[id]?.login = login
    }

    public mutating func describe(_ id: String, title: String?, project: String?) {
        entries[id]?.title = title
        entries[id]?.project = project
    }

    public mutating func runs(_ id: String, in remote: String?) {
        entries[id]?.remote = remote
    }

    public func recovery(_ id: String) -> Recovery {
        guard let entry = entries[id], entry.role == .source else { return .nothing }
        switch entry.step {
        case .prepared, .held, .sent: return .rollBack
        case .committing, .unknown: return .ask
        default: return .nothing
        }
    }

    /// Settles a source entry from the destination's answer. Returns whether the session is to start here again.
    public mutating func settle(_ id: String, peerSays status: PeerStatus, at: Double) -> Bool {
        guard let entry = entries[id], entry.role == .source, entry.step == .committing || entry.step == .unknown else { return false }
        switch status {
        case .live:
            advance(id, to: .away, at: at)
            return false
        case .none, .discarded:
            advance(id, to: .returned, at: at)
            return true
        case .staging, .staged, .starting:
            // Not started yet, but it could be on the next request, or is starting now: the source waits, or tells
            // it to drop the copy first.
            if entry.step == .committing { advance(id, to: .unknown, at: at) }
            return false
        }
    }

    /// The session came back from the other computer, or the user chose to run a copy here.
    public mutating func returned(_ id: String, at: Double) {
        advance(id, to: .returned, at: at)
    }

    // MARK: Destination

    /// Starts receiving. Refused when this move was already dropped or finished here.
    public mutating func receive(_ entry: Entry) -> Bool {
        if let known = entries[entry.id] { return known.step == .staging }
        entries[entry.id] = entry
        return true
    }

    public mutating func staged(_ id: String, folder: String, name: String, at: Double) -> Bool {
        guard entries[id]?.role == .destination, advance(id, to: .staged, at: at) else { return false }
        entries[id]?.folder = folder
        entries[id]?.name = name
        return true
    }

    /// The source asks for the session to start.
    public mutating func commit(_ id: String, at: Double) -> Verdict {
        guard let entry = entries[id], entry.role == .destination else { return .refused }
        switch entry.step {
        case .staged:
            advance(id, to: .starting, at: at)
            return .start
        case .starting: return .starting
        case .live, .gone: return .alreadyLive
        default: return .refused
        }
    }

    /// The source asks for the copy to be dropped. True when the caller has files to remove. A move this computer
    /// never saw is written down as dropped, so a start request that arrives late is refused.
    public mutating func abort(_ id: String, session: String, agent: String, peer: String, peerName: String, at: Double) -> (dropped: Bool, status: PeerStatus) {
        guard let entry = entries[id] else {
            entries[id] = Entry(id: id, role: .destination, session: session, agent: agent, peer: peer, peerName: peerName, step: .discarded, at: at)
            return (false, .none)
        }
        guard entry.role == .destination else { return (false, .none) }
        switch entry.step {
        case .staging, .staged:
            advance(id, to: .discarded, at: at)
            return (true, .discarded)
        case .starting: return (false, .starting)
        case .live, .gone: return (false, .live)
        default: return (false, .discarded)
        }
    }

    public func status(_ id: String) -> PeerStatus {
        guard let entry = entries[id], entry.role == .destination else { return .none }
        switch entry.step {
        case .staging: return .staging
        case .staged: return .staged
        case .starting: return .starting
        case .live, .gone: return .live
        default: return .discarded
        }
    }

    /// The session started here.
    @discardableResult
    public mutating func started(_ id: String, at: Double) -> Bool { advance(id, to: .live, at: at) }

    /// It was asked to start and did not: nothing of it runs here.
    public mutating func failed(_ id: String, at: Double) { advance(id, to: .discarded, at: at) }

    /// A session that arrived and ran left again for another computer. To the computer that sent it here it still
    /// started, so it must never start it again on this computer's answer.
    public mutating func ended(_ id: String, at: Double) { advance(id, to: .gone, at: at) }

    // MARK: Both

    /// Where a conversation is. The newest unfinished entry decides.
    public func ownership(of session: String) -> Ownership {
        let mine = entries.values.filter { $0.session == session }.sorted { $0.startedAt > $1.startedAt }
        for entry in mine {
            switch entry.step {
            case .prepared, .live, .gone, .returned, .discarded: continue
            case .held, .sent: return .leaving(peer: entry.peer)
            case .committing, .unknown: return .unknown(peer: entry.peer)
            case .away: return .away(peer: entry.peer)
            case .staging, .staged, .starting: return .arriving(peer: entry.peer)
            }
        }
        return .here
    }

    /// The entry that says where `session` is, when it is not simply here.
    public func open(for session: String) -> Entry? {
        entries.values.filter { $0.session == session && ![.prepared, .live, .gone, .returned, .discarded].contains($0.step) }
            .max { $0.startedAt < $1.startedAt }
    }

    /// Staged copies the source never asked to start, to be dropped; and old finished entries, forgotten.
    public mutating func expire(now: Double) -> [Entry] {
        let stale = entries.values.filter { ($0.step == .staged || $0.step == .staging) && now - $0.updatedAt >= Self.stagedFor }
        for entry in stale { advance(entry.id, to: .discarded, at: now) }
        entries = entries.filter { ![.returned, .discarded, .gone].contains($0.value.step) || now - $0.value.updatedAt < Self.remembered }
        return stale.sorted { $0.startedAt < $1.startedAt }
    }
}
