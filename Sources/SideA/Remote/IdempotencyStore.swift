import CryptoKit
import Foundation
import SQLite3

/// `Idempotency-Key` records per device, on disk so they outlive a relaunch while tmux sessions may not. A record is
/// written `started` before the effect and `done` with the response after; a `started` one left by an earlier process
/// means nobody knows whether the effect happened, so it is never run again. Used only on the server's queue.
final class IdempotencyStore {
    static let maxAge: TimeInterval = 86_400
    static let perDevice = 1_000
    static let maxKey = 128

    enum Lookup: Equatable {
        /// Run it, then `finish`.
        case run
        case replay(status: Int, contentType: String?, body: Data)
        /// 422 `idempotency_mismatch`: the same key with another method, path or body.
        case mismatch
        /// The first is still running in this process; wait for it.
        case running
        /// 409 `outcome_unknown`: started by an earlier process that never recorded the result.
        case unknown
        /// 503 `not_ready`: the `started` record couldn't be written, so nothing may run.
        case unavailable
    }

    private var db: OpaquePointer?
    private var running: Set<String> = []
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// nil keeps the records in memory, for tests. A file that can't be opened leaves no database at all, so every
    /// request that needs a record is refused rather than run unrecorded.
    init(url: URL?) {
        if let url {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
                sqlite3_close(db); db = nil
                return
            }
            chmod(url.path, 0o600)
        } else {
            sqlite3_open(":memory:", &db)
        }
        exec("PRAGMA journal_mode=WAL")
        exec("""
            CREATE TABLE IF NOT EXISTS records (device TEXT NOT NULL, key TEXT NOT NULL, method TEXT NOT NULL, path TEXT NOT NULL,
              body_hash BLOB NOT NULL, state TEXT NOT NULL, status INTEGER, content_type TEXT, response BLOB, created REAL NOT NULL,
              PRIMARY KEY (device, key))
            """)
        trim(now: Date().timeIntervalSince1970)
    }

    deinit { sqlite3_close(db) }

    func begin(device: String, key: String, method: String, path: String, body: Data, now: TimeInterval) -> Lookup {
        let hash = Data(SHA256.hash(data: body))
        if let row = row(device, key), now - row.created <= Self.maxAge {
            guard row.method == method, row.path == path, row.hash == hash else { return .mismatch }
            if row.state == "done" { return .replay(status: row.status, contentType: row.contentType, body: row.response) }
            return running.contains(device + "\n" + key) ? .running : .unknown
        }
        // Durable before the effect: a crash after this line leaves `started`, never a second run.
        exec("PRAGMA synchronous=FULL")
        let written = run("INSERT OR REPLACE INTO records (device, key, method, path, body_hash, state, created) VALUES (?, ?, ?, ?, ?, 'started', ?)",
                          [.text(device), .text(key), .text(method), .text(path), .blob(hash), .real(now)])
        exec("PRAGMA synchronous=NORMAL")
        guard written else { return .unavailable }
        running.insert(device + "\n" + key)
        return .run
    }

    /// Answers worth retrying (429, 5xx) are dropped, so the retry runs again: they promise nothing happened. So is a
    /// refused signature (401), or a call that has only the token would spoil the key for the phone's signed one. So is
    /// any other refusal a stronger proof would change: the proof is in a header, outside the record's hash, so a stored
    /// refusal would answer the Face ID retry too.
    func finish(device: String, key: String, status: Int, contentType: String?, body: Data) {
        running.remove(device + "\n" + key)
        if status == 401 || status == 429 || status >= 500 || Self.wantsProof(status: status, body: body) {
            run("DELETE FROM records WHERE device = ? AND key = ?", [.text(device), .text(key)])
            return
        }
        run("UPDATE records SET state = 'done', status = ?, content_type = ?, response = ? WHERE device = ? AND key = ?",
            [.int(status), contentType.map(Value.text) ?? .null, .blob(body), .text(device), .text(key)])
        run("""
            DELETE FROM records WHERE device = ? AND rowid NOT IN
              (SELECT rowid FROM records WHERE device = ? ORDER BY created DESC LIMIT \(Self.perDevice))
            """, [.text(device), .text(device)])
    }

    static func wantsProof(status: Int, body: Data) -> Bool {
        guard status == 409 || status == 422,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let error = object["error"] as? [String: Any] else { return false }
        switch (status, error["code"] as? String) {
        case (409, "gate_changed"): return true
        case (422, "invalid_answer"): return (error["details"] as? [String: Any])?["reason"] as? String == "needs_confirm"
        default: return false
        }
    }

    func forget(device: String) { run("DELETE FROM records WHERE device = ?", [.text(device)]) }

    /// At launch and hourly: 24 hours and 1,000 per device.
    func trim(now: TimeInterval) {
        run("DELETE FROM records WHERE created < ?", [.real(now - Self.maxAge)])
        run("""
            DELETE FROM records WHERE rowid IN (SELECT rowid FROM
              (SELECT rowid, ROW_NUMBER() OVER (PARTITION BY device ORDER BY created DESC) AS n FROM records) WHERE n > \(Self.perDevice))
            """, [])
    }

    func count(_ device: String) -> Int {
        var count = 0
        query("SELECT COUNT(*) FROM records WHERE device = ?", [.text(device)]) { count = Int(sqlite3_column_int64($0, 0)) }
        return count
    }

    // MARK: SQLite

    private enum Value { case text(String), blob(Data), int(Int), real(Double), null }

    private struct Row { let method, path: String; let hash: Data; let state: String; let status: Int; let contentType: String?; let response: Data; let created: Double }

    private func row(_ device: String, _ key: String) -> Row? {
        var found: Row?
        query("SELECT method, path, body_hash, state, status, content_type, response, created FROM records WHERE device = ? AND key = ?",
              [.text(device), .text(key)]) { statement in
            found = Row(method: Self.text(statement, 0) ?? "", path: Self.text(statement, 1) ?? "", hash: Self.blob(statement, 2),
                        state: Self.text(statement, 3) ?? "", status: Int(sqlite3_column_int64(statement, 4)),
                        contentType: Self.text(statement, 5), response: Self.blob(statement, 6), created: sqlite3_column_double(statement, 7))
        }
        return found
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    @discardableResult
    private func run(_ sql: String, _ values: [Value]) -> Bool { query(sql, values) { _ in } }

    /// Whether the statement ran to the end.
    @discardableResult
    private func query(_ sql: String, _ values: [Value], row: (OpaquePointer?) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard db != nil, sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, i, text, -1, Self.transient)
            case .blob(let data): _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, i, $0.baseAddress, Int32(data.count), Self.transient) }
            case .int(let number): sqlite3_bind_int64(statement, i, Int64(number))
            case .real(let number): sqlite3_bind_double(statement, i, number)
            case .null: sqlite3_bind_null(statement, i)
            }
        }
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            row(statement)
            step = sqlite3_step(statement)
        }
        return step == SQLITE_DONE
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private static func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
