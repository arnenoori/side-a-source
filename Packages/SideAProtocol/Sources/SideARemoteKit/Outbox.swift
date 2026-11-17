import Foundation
import SideAProtocol
import SQLite3

/// Mutations waiting for the Mac, in a table of the App Group's `shared.sqlite`, so the app, its
/// notification actions, the Content Extension and App Intents share one queue across processes.
/// Every read-modify-write is one short `BEGIN IMMEDIATE` transaction, never held across an `await`.
/// Each item's id is its Idempotency-Key.
public actor Outbox {
    public struct Item: Codable, Sendable, Identifiable, Equatable {
        /// Also the Idempotency-Key.
        public let id: String
        public let macID: String
        public let method: String
        public let path: String
        public let body: Data
        public let createdAt: Timestamp
        public var attempts: Int
        public var lastError: APIError?
        /// Answers: 24 h; replies and interrupts: 10 min.
        public let expiresAt: Timestamp
        /// A retry the user tapped: the first attempt's id, and which retry this is (1, 2, …).
        public let retryOf: String?
        public let retry: Int?
        /// `X-SideA-Confirm`, signed when the user answered; good for two minutes, so a later retry needs a new tap.
        public var confirm: String?

        public init(id: String = UUID().uuidString.lowercased(), macID: String, method: String = "POST", path: String, body: Data = Data(),
                    createdAt: Timestamp, attempts: Int = 0, lastError: APIError? = nil, expiresAt: Timestamp,
                    retryOf: String? = nil, retry: Int? = nil, confirm: String? = nil) {
            self.id = id; self.macID = macID; self.method = method; self.path = path; self.body = body
            self.createdAt = createdAt; self.attempts = attempts; self.lastError = lastError; self.expiresAt = expiresAt
            self.retryOf = retryOf; self.retry = retry; self.confirm = confirm
        }

        /// The same mutation under a new Idempotency-Key, `<first id>:r<n>` (an answer's is `<rid>:<kind>:r<n>`),
        /// for the same lifetime counted from `now`.
        public func retried(_ n: Int, now: Timestamp, confirm: String? = nil) -> Item {
            let first = retryOf ?? id
            return Item(id: "\(first):r\(n)", macID: macID, method: method, path: path, body: body, createdAt: now,
                        expiresAt: now + (expiresAt - createdAt), retryOf: first, retry: n, confirm: confirm)
        }

        /// What the item acts on, so items for one session or request go in order and a retrying one
        /// holds back only those: `request:<rid>`, `session:<id>`, or the path for anything else.
        public var target: String { QueuedRoutes.target(ofPath: path) }

        /// The request an answer is for, from `/v1/requests/{rid}/answer`.
        public var answering: RequestID? { QueuedRoutes.answering(path: path) }

        /// An answer's first key, `<rid>:<kind>`: the app and a notification action make the same one, so a second tap is a replay.
        public static func answerID(_ request: RequestID, _ answer: RemoteAnswer, mode: PermissionMode? = nil) -> String {
            "\(request):\((mode == nil ? answer.kind : .allowMode).rawValue)"
        }

        /// An answer, byte for byte the same from the app's engine and a notification action.
        public static func answer(_ request: RequestID, _ answer: RemoteAnswer, mode: PermissionMode? = nil, id: String? = nil, macID: String,
                                  now: Timestamp, confirm: String? = nil) -> Item {
            let body = (try? RemoteClient.encoder.encode(AnswerBody(answer: answer, mode: mode))) ?? Data()
            return Item(id: id ?? answerID(request, answer, mode: mode), macID: macID, method: QueuedRoutes.answer.method,
                        path: QueuedRoutes.answer.path(request), body: body, createdAt: now, expiresAt: now + 86_400, confirm: confirm)
        }

        /// A reply to a session; a finished one needs its `FinishedSession.turnID`.
        public static func reply(_ session: SessionKey, _ reply: RemoteReply, id: String = UUID().uuidString.lowercased(), macID: String,
                                 now: Timestamp, confirm: String? = nil) -> Item {
            let body = (try? RemoteClient.encoder.encode(reply)) ?? Data()
            return Item(id: id, macID: macID, method: QueuedRoutes.reply.method, path: QueuedRoutes.reply.path(session), body: body,
                        createdAt: now, expiresAt: now + 600, confirm: confirm)
        }
    }

    public enum Failure: Error {
        case open(String)
        /// A write the database refused: the disk is full, or another process held the write lock past the timeout.
        case write(String)
    }

    /// A claim older than this is free again: its process died or was suspended mid-send.
    public static let claimLifetime: Double = 30

    /// Owns the connection so it closes with the actor.
    private final class Handle: @unchecked Sendable {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { sqlite3_close(pointer) }
    }
    private let handle: Handle
    private var db: OpaquePointer { handle.pointer }

    /// Opens or creates the store at `file`, in the App Group container. A write waits `busyTimeout` for another
    /// process's write lock before it fails.
    public init(file: URL, busyTimeout: Int32 = 5000) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(file.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
            sqlite3_close(pointer)
            throw Failure.open(message)
        }
        handle = Handle(pointer)
        // Another process may hold the write lock for a moment; wait for it instead of failing.
        sqlite3_busy_timeout(pointer, busyTimeout)
        for statement in ["PRAGMA journal_mode=WAL",
                          """
                          CREATE TABLE IF NOT EXISTS outbox(id TEXT PRIMARY KEY, mac TEXT NOT NULL, target TEXT NOT NULL, created REAL NOT NULL,
                              answer INTEGER NOT NULL, item BLOB NOT NULL, claimedBy TEXT, claimedAt REAL)
                          """,
                          "CREATE TABLE IF NOT EXISTS reply_flight(item TEXT PRIMARY KEY, mac TEXT NOT NULL, flight BLOB NOT NULL)",
                          "CREATE TABLE IF NOT EXISTS terminal_input(viewer TEXT NOT NULL, seq INTEGER NOT NULL, epoch TEXT NOT NULL, bytes BLOB NOT NULL, PRIMARY KEY(viewer, seq))"] {
            guard sqlite3_exec(pointer, statement, nil, nil, nil) == SQLITE_OK else { throw Failure.open(String(cString: sqlite3_errmsg(pointer))) }
        }
    }

    /// Adds the item unless one with its id is already queued (a retried notification action). Throws when it could not
    /// be written (the disk is full, or another process held the write lock past the timeout): the item is then in no
    /// queue, and the caller says so instead of showing it as waiting.
    public func enqueue(_ item: Item) throws {
        let data = try JSONEncoder().encode(item)
        try transaction {
            try run("INSERT OR IGNORE INTO outbox(id, mac, target, created, answer, item) VALUES(?, ?, ?, ?, ?, ?)",
                    .text(item.id), .text(item.macID), .text(item.target), .real(item.createdAt), .int(item.answering == nil ? 0 : 1), .blob(data))
        }
    }

    /// Records an attempt on an item still queued.
    public func update(_ item: Item) {
        guard let data = try? JSONEncoder().encode(item) else { return }
        attempt("update") { try run("UPDATE outbox SET item = ? WHERE id = ?", .blob(data), .text(item.id)) }
    }

    /// Oldest first, claimed or not.
    public func items(for macID: String) -> [Item] { read(for: macID) ?? [] }

    /// `items`, or nil when the database couldn't be read: the caller keeps what it had instead of showing an empty queue.
    public func read(for macID: String) -> [Item]? {
        var rows: [Item] = []
        do {
            try run("SELECT item FROM outbox WHERE mac = ? ORDER BY created, id", .text(macID)) { rows += Self.item($0, 0).map { [$0] } ?? [] }
        } catch {
            KitLog.log(.sync, "outbox read failed: \(error)")
            return nil
        }
        return rows
    }

    /// Takes the next item to send for `macID`, answers first, so no other process sends it meanwhile.
    /// Items for a target in `held` are skipped, and so is a target whose oldest item another process holds,
    /// so each target still goes in order.
    public func claim(for macID: String, by owner: String, now: Timestamp, skipping held: Set<String> = []) -> Item? {
        var claimed: Item?
        // A row that no longer decodes would be the oldest of its target for good, so it goes and the next is tried.
        var unreadable = true
        while unreadable {
            unreadable = false
            var deletions: [String] = []
            let done = attempt("claim") {
                let free = "(claimedBy IS NULL OR claimedBy = ? OR claimedAt < ?)"
                try run("""
                    SELECT id, item FROM outbox AS o WHERE mac = ? AND \(free)
                    AND target NOT IN (\(held.map { _ in "?" }.joined(separator: ",")))
                    AND NOT EXISTS (SELECT 1 FROM outbox AS e WHERE e.mac = o.mac AND e.target = o.target
                        AND (e.created < o.created OR (e.created = o.created AND e.id < o.id)))
                    ORDER BY answer DESC, created, id LIMIT 1
                    """, values: [.text(macID), .text(owner), .real(now - Self.claimLifetime)] + held.sorted().map { .text($0) }) { statement in
                    if let item = Self.item(statement, 1) {
                        claimed = item
                    } else {
                        unreadable = true
                        deletions.append(String(cString: sqlite3_column_text(statement, 0)))
                    }
                }
                for id in deletions { try run("DELETE FROM outbox WHERE id = ?", .text(id)) }
                if let claimed { try run("UPDATE outbox SET claimedBy = ?, claimedAt = ? WHERE id = ?", .text(owner), .real(now), .text(claimed.id)) }
            }
            // A transaction that failed claimed nothing: the next drain asks again.
            if !done { claimed = nil; break }
        }
        return claimed
    }

    /// Takes the items of `macID` past their `expiresAt` that nobody is sending, in any order: the engine settles them
    /// as undelivered whether or not it is connected.
    public func claimExpired(for macID: String, by owner: String, now: Timestamp) -> [Item] {
        var expired: [Item] = []
        let done = attempt("claim expired") {
            expired = []
            try run("SELECT item FROM outbox WHERE mac = ? AND (claimedBy IS NULL OR claimedAt < ?)",
                    .text(macID), .real(now - Self.claimLifetime)) { statement in
                if let item = Self.item(statement, 0), item.expiresAt <= now { expired.append(item) }
            }
            for item in expired { try run("UPDATE outbox SET claimedBy = ?, claimedAt = ? WHERE id = ?", .text(owner), .real(now), .text(item.id)) }
        }
        // Rolled back: none of them is claimed, so none is settled; the next check finds them again.
        return done ? expired : []
    }

    /// Gives an item back to the queue after a failed attempt.
    public func release(_ id: String) {
        attempt("release") { try run("UPDATE outbox SET claimedBy = NULL, claimedAt = NULL WHERE id = ?", .text(id)) }
    }

    public func remove(_ id: String) {
        attempt("remove") { try run("DELETE FROM outbox WHERE id = ?", .text(id)) }
    }

    // MARK: Reply flights

    /// A reply's record beside its item, by that item's id; nil removes it.
    public func setFlight(_ flight: ReplyFlight?, item: String, mac: String) {
        attempt("flight") {
            if let flight, let data = try? JSONEncoder().encode(flight) {
                try run("INSERT OR REPLACE INTO reply_flight(item, mac, flight) VALUES(?, ?, ?)", .text(item), .text(mac), .blob(data))
            } else {
                try run("DELETE FROM reply_flight WHERE item = ?", .text(item))
            }
        }
    }

    public func flights(for macID: String) -> [String: ReplyFlight] {
        var flights: [String: ReplyFlight] = [:]
        try? run("SELECT item, flight FROM reply_flight WHERE mac = ?", .text(macID)) { statement in
            if let flight = try? JSONDecoder().decode(ReplyFlight.self, from: Self.blob(statement, 1)) {
                flights[String(cString: sqlite3_column_text(statement, 0))] = flight
            }
        }
        return flights
    }

    public func removeFlights(for macID: String) {
        attempt("flights") { try run("DELETE FROM reply_flight WHERE mac = ?", .text(macID)) }
    }

    // MARK: Terminal input

    /// Unacked input frames of one terminal view, with the epoch they were sent under; oldest first.
    public func terminalInput(viewer: String) -> [(seq: UInt32, epoch: String, bytes: Data)] {
        var rows: [(UInt32, String, Data)] = []
        try? run("SELECT seq, epoch, bytes FROM terminal_input WHERE viewer = ? ORDER BY seq", .text(viewer)) { statement in
            rows.append((UInt32(sqlite3_column_int64(statement, 0)), String(cString: sqlite3_column_text(statement, 1)), Self.blob(statement, 2)))
        }
        return rows
    }

    public func addTerminalInput(viewer: String, seq: UInt32, epoch: String, bytes: Data) {
        attempt("terminal input") {
            try run("INSERT OR REPLACE INTO terminal_input(viewer, seq, epoch, bytes) VALUES(?, ?, ?, ?)",
                .text(viewer), .int(Int64(seq)), .text(epoch), .blob(bytes))
        }
    }

    /// Drops frames up to and including `seq`: the Mac has them. Nil drops them all.
    public func dropTerminalInput(viewer: String, through seq: UInt32? = nil) {
        attempt("terminal input") {
            if let seq { try run("DELETE FROM terminal_input WHERE viewer = ? AND seq <= ?", .text(viewer), .int(Int64(seq))) }
            else { try run("DELETE FROM terminal_input WHERE viewer = ?", .text(viewer)) }
        }
    }

    // MARK: SQLite

    private enum Value { case text(String), real(Double), int(Int64), blob(Data) }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private static func item(_ statement: OpaquePointer, _ column: Int32) -> Item? {
        try? JSONDecoder().decode(Item.self, from: blob(statement, column))
    }

    /// One short write transaction, rolled back and thrown if any step of it fails; the body never awaits.
    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// A write nobody is waiting on: a failure is logged, and the next attempt starts from what the database holds.
    @discardableResult
    private func attempt(_ what: String, _ body: () throws -> Void) -> Bool {
        do {
            try transaction(body)
            return true
        } catch {
            KitLog.log(.sync, "outbox \(what) failed: \(error)")
            return false
        }
    }

    private func exec(_ sql: String) throws {
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw Failure.write(Self.message(code, db)) }
    }

    private static func message(_ code: Int32, _ db: OpaquePointer?) -> String {
        "\(code): \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle")"
    }

    private func run(_ sql: String, _ values: Value..., row: (OpaquePointer) -> Void = { _ in }) throws {
        try run(sql, values: values, row: row)
    }

    private func run(_ sql: String, values: [Value], row: (OpaquePointer) -> Void = { _ in }) throws {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw Failure.write(Self.message(prepared, db)) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let slot = Int32(index + 1)
            let bound: Int32
            switch value {
            case .text(let text): bound = sqlite3_bind_text(statement, slot, text, -1, Self.transient)
            case .real(let number): bound = sqlite3_bind_double(statement, slot, number)
            case .int(let number): bound = sqlite3_bind_int64(statement, slot, number)
            case .blob(let data): bound = data.withUnsafeBytes { sqlite3_bind_blob(statement, slot, $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(data.count), Self.transient) }
            }
            guard bound == SQLITE_OK else { throw Failure.write(Self.message(bound, db)) }
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { row(statement); continue }
            guard step == SQLITE_DONE else { throw Failure.write(Self.message(step, db)) }
            break
        }
    }
}
