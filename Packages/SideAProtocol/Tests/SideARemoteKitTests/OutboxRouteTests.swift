import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import SQLite3
import Testing

// What every queued mutation looks like on the wire and in the shared database. These are literals on purpose: the paths
// are the Mac's routes and the targets are what rows already written under them hold, so a change to how either is
// built from a descriptor has to leave every one of them as it is.

private let rid = "5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b"
private let sid = "8c1d2f3e-4a5b-4c6d-8e7f-9a0b1c2d3e4f"

private struct Shape: Equatable {
    var method: String
    var path: String
    var target: String
    var answering: RequestID?
    var answer: Int
}

private func shape(_ item: Outbox.Item) -> Shape {
    Shape(method: item.method, path: item.path, target: item.target, answering: item.answering, answer: item.answering == nil ? 0 : 1)
}

@Test func everyQueuedMutationHasItsLiteralMethodPathAndTarget() async throws {
    let sync = try engine(FakeMac())
    let answer = await sync.answer(rid, .allow(confirmDestructive: false))
    let reply = await sync.reply(sid, RemoteReply(text: "go on"))
    let interrupt = await sync.interrupt(sid)
    let takeBack = await sync.takeBack(sessionID: sid)
    #expect(shape(answer) == Shape(method: "POST", path: "/v1/requests/\(rid)/answer", target: "request:\(rid)", answering: rid, answer: 1))
    #expect(shape(reply) == Shape(method: "POST", path: "/v1/sessions/\(sid)/reply", target: "session:\(sid)", answering: nil, answer: 0))
    #expect(shape(interrupt) == Shape(method: "POST", path: "/v1/sessions/\(sid)/interrupt", target: "session:\(sid)", answering: nil, answer: 0))
    #expect(shape(takeBack) == Shape(method: "DELETE", path: "/v1/sessions/\(sid)/mail", target: "session:\(sid)", answering: nil, answer: 0))

    // What a notification action makes is the same item.
    let fromAction = Outbox.Item.answer(rid, .deny(message: nil), macID: "mac1", now: 1)
    #expect(shape(fromAction) == Shape(method: "POST", path: "/v1/requests/\(rid)/answer", target: "request:\(rid)", answering: rid, answer: 1))
    let replyFromAction = Outbox.Item.reply(sid, RemoteReply(text: "x"), macID: "mac1", now: 1)
    #expect(shape(replyFromAction) == Shape(method: "POST", path: "/v1/sessions/\(sid)/reply", target: "session:\(sid)", answering: nil, answer: 0))
}

@Test func theTargetAndAnsweringOfAPathNoDescriptorNamesAreWhatTheySplitInto() {
    func item(_ path: String) -> Outbox.Item { Outbox.Item(macID: "mac1", path: path, createdAt: 1, expiresAt: 2) }
    #expect(item("/v1/requests/r1/answer").target == "request:r1" && item("/v1/requests/r1/answer").answering == "r1")
    #expect(item("/v1/requests/r1/other").target == "request:r1" && item("/v1/requests/r1/other").answering == nil)
    #expect(item("/v1/requests/r1").target == "request:r1" && item("/v1/requests/r1").answering == nil)
    #expect(item("/v1/sessions/s1/anything/else").target == "session:s1")
    #expect(item("/v1/sessions/s1").target == "session:s1")
    #expect(item("/v1/sessions").target == "/v1/sessions" && item("/v1/state").target == "/v1/state" && item("").target == "")
    #expect(item("/x/requests/r2/answer").target == "request:r2" && item("/x/requests/r2/answer").answering == "r2")
    // The id is read as written for the target, and decoded for the request it answers.
    #expect(item("/v1/requests/a%2Fb/answer").target == "request:a%2Fb" && item("/v1/requests/a%2Fb/answer").answering == "a/b")
    #expect(item("//v1//requests//r3//answer//").target == "request:r3" && item("//v1//requests//r3//answer//").answering == "r3")
}

/// Rows written before descriptors existed: the items as they were stored, and the target column as it was written.
@Test func rowsWrittenByTheOldCodeAreReadAndClaimedTheSame() async throws {
    let fixtures: [(String, Shape)] = [
        ("kit/OutboxItem.answer", Shape(method: "POST", path: "/v1/requests/\(rid)/answer", target: "request:\(rid)", answering: rid, answer: 1)),
        ("kit/OutboxItem.retry", Shape(method: "POST", path: "/v1/requests/\(rid)/answer", target: "request:\(rid)", answering: rid, answer: 1)),
        ("kit/OutboxItem.reply", Shape(method: "POST", path: "/v1/sessions/\(sid)/reply", target: "session:\(sid)", answering: nil, answer: 0)),
        ("kit/OutboxItem.interrupt", Shape(method: "POST", path: "/v1/sessions/\(sid)/interrupt", target: "session:\(sid)", answering: nil, answer: 0)),
        ("kit/OutboxItem.take-back", Shape(method: "DELETE", path: "/v1/sessions/\(sid)/mail", target: "session:\(sid)", answering: nil, answer: 0)),
    ]
    let (outbox, file) = try temporaryOutbox()
    var db: OpaquePointer?
    #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    var decoded: [Outbox.Item] = []
    for (index, (name, expected)) in fixtures.enumerated() {
        let data = try Fixtures.data(name)
        let item = try JSONDecoder().decode(Outbox.Item.self, from: data)
        #expect(shape(item) == expected, "\(name)")
        decoded.append(item)
        // Inserted as the old code did: its own column values, its item as the JSON it encoded.
        var statement: OpaquePointer?
        let sql = "INSERT INTO outbox(id, mac, target, created, answer, item) VALUES(?, ?, ?, ?, ?, ?)"
        #expect(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, item.id, -1, transient)
        sqlite3_bind_text(statement, 2, item.macID, -1, transient)
        sqlite3_bind_text(statement, 3, expected.target, -1, transient)
        sqlite3_bind_double(statement, 4, item.createdAt + Double(index))
        sqlite3_bind_int64(statement, 5, Int64(expected.answer))
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 6, $0.baseAddress, Int32(data.count), transient) }
        #expect(sqlite3_step(statement) == SQLITE_DONE)
        sqlite3_finalize(statement)
    }
    let mac = decoded[0].macID
    // The queue reads them back, and a held target skips exactly the rows its old column named.
    #expect(await outbox.items(for: mac).map(\.id).sorted() == decoded.map(\.id).sorted())
    #expect(await outbox.claim(for: mac, by: "o", now: 1_791_560_100, skipping: ["request:\(rid)"])?.id == decoded[2].id)
    #expect(await outbox.claim(for: mac, by: "p", now: 1_791_560_100, skipping: ["request:\(rid)", "session:\(sid)"]) == nil)
    // Answers go first, then the oldest of a target: the same order a new row gets.
    let first = await outbox.claim(for: mac, by: "q", now: 1_791_560_100)
    #expect(first?.answering == rid)
}

/// What the engine writes now is what the old code wrote: the same columns for the same item.
@Test func aNewRowHoldsTheColumnsTheOldCodeWrote() async throws {
    let (outbox, file) = try temporaryOutbox()
    let answer = Outbox.Item.answer(rid, .allow(confirmDestructive: false), macID: "mac1", now: 10)
    let takeBack = Outbox.Item(id: "t", macID: "mac1", method: "DELETE", path: "/v1/sessions/\(sid)/mail", createdAt: 11, expiresAt: 21)
    try await outbox.enqueue(answer)
    try await outbox.enqueue(takeBack)
    var db: OpaquePointer?
    #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(db, "SELECT id, target, answer FROM outbox ORDER BY created", -1, &statement, nil) == SQLITE_OK)
    var rows: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        rows.append("\(String(cString: sqlite3_column_text(statement, 0))) \(String(cString: sqlite3_column_text(statement, 1))) \(sqlite3_column_int(statement, 2))")
    }
    sqlite3_finalize(statement)
    #expect(rows == ["\(rid):allow request:\(rid) 1", "t session:\(sid) 0"])
}
