import Foundation
@testable import SideA
import Testing

private func temporary() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sidea-idem-\(UUID().uuidString)/idempotency.sqlite")
}

@Test func aDoneRecordReplaysAfterARelaunchAndAStartedOneIsUnknown() {
    let url = temporary()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let body = Data(#"{"answer":{"kind":"allow"}}"#.utf8), base = Date().timeIntervalSince1970
    do {
        let store = IdempotencyStore(url: url)
        #expect(store.begin(device: "d1", key: "done", method: "POST", path: "/v1/requests/r/answer", body: body, now: base) == .run)
        #expect(store.begin(device: "d1", key: "done", method: "POST", path: "/v1/requests/r/answer", body: body, now: base) == .running)
        store.finish(device: "d1", key: "done", status: 200, contentType: "application/json", body: Data("{}".utf8))
        #expect(store.begin(device: "d1", key: "crashed", method: "POST", path: "/v1/sessions/s/reply", body: body, now: base) == .run)
        #expect(store.begin(device: "d1", key: "busy", method: "POST", path: "/v1/x", body: body, now: base) == .run)
        store.finish(device: "d1", key: "busy", status: 503, contentType: nil, body: Data())
    }
    let again = IdempotencyStore(url: url)
    #expect(again.begin(device: "d1", key: "done", method: "POST", path: "/v1/requests/r/answer", body: body, now: base + 1)
            == .replay(status: 200, contentType: "application/json", body: Data("{}".utf8)))
    // The handler never ran to the end: the retry must not run it again.
    #expect(again.begin(device: "d1", key: "crashed", method: "POST", path: "/v1/sessions/s/reply", body: body, now: base + 1) == .unknown)
    // A 503 promised nothing happened, so its retry runs.
    #expect(again.begin(device: "d1", key: "busy", method: "POST", path: "/v1/x", body: body, now: base + 1) == .run)
    #expect(again.begin(device: "d1", key: "done", method: "POST", path: "/v1/requests/r/answer", body: Data("x".utf8), now: base + 1) == .mismatch)
    #expect(again.begin(device: "d1", key: "done", method: "DELETE", path: "/v1/requests/r/answer", body: body, now: base + 1) == .mismatch)
    #expect(again.begin(device: "d2", key: "done", method: "POST", path: "/v1/requests/r/answer", body: body, now: base + 1) == .run)
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes?[.posixPermissions] as? Int) == 0o600)
}

@Test func recordsAreTrimmedToADayAndAThousandPerDevice() {
    let store = IdempotencyStore(url: nil)
    for i in 0..<1_003 {
        _ = store.begin(device: "d", key: "\(i)", method: "POST", path: "/p", body: Data(), now: Double(i))
        store.finish(device: "d", key: "\(i)", status: 200, contentType: nil, body: Data())
    }
    #expect(store.count("d") == 1_000)
    #expect(store.begin(device: "d", key: "0", method: "POST", path: "/p", body: Data(), now: 1_004) == .run)
    store.trim(now: 1_002 + 86_401)
    #expect(store.count("d") == 1)
    store.forget(device: "d")
    #expect(store.count("d") == 0)
}

@Test func nothingRunsUnrecorded() throws {
    let url = temporary()
    let folder = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // A folder where the file should be: it can't be opened, and there's no quiet fallback to memory.
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("taken"), withIntermediateDirectories: true)
    let unopened = IdempotencyStore(url: folder.appendingPathComponent("taken"))
    #expect(unopened.begin(device: "d1", key: "k", method: "POST", path: "/v1/x", body: Data(), now: 1) == .unavailable)
    // A file that opens but can't be written to.
    _ = IdempotencyStore(url: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
    let readOnly = IdempotencyStore(url: url)
    #expect(readOnly.begin(device: "d1", key: "k", method: "POST", path: "/v1/x", body: Data(), now: 1) == .unavailable)
}

private func refusal(_ code: String, reason: String? = nil) -> Data {
    var error: [String: Any] = ["code": code, "message": "no"]
    if let reason { error["details"] = ["reason": reason] }
    return try! JSONSerialization.data(withJSONObject: ["error": error])
}

/// The proof is in a header, outside the record's hash: a refusal it could change must not answer the retry that has it.
@Test func aRefusalAProofCouldChangeIsNotReplayed() {
    let store = IdempotencyStore(url: nil)
    let body = Data("{}".utf8)
    let begin = { store.begin(device: "d", key: "r:allow", method: "POST", path: "/p", body: body, now: 1) }
    for (status, refused) in [(409, refusal("gate_changed")), (422, refusal("invalid_answer", reason: "needs_confirm"))] {
        #expect(begin() == .run)
        store.finish(device: "d", key: "r:allow", status: status, contentType: "application/json", body: refused)
    }
    #expect(begin() == .run)
    store.finish(device: "d", key: "r:allow", status: 200, contentType: "application/json", body: body)
    #expect(begin() == .replay(status: 200, contentType: "application/json", body: body))
}

/// No proof changes these, and a retry must not act on them twice.
@Test func aRefusalNoProofCanChangeIsStillReplayed() {
    let store = IdempotencyStore(url: nil)
    for (n, (status, refused)) in [(409, refusal("already_resolved")), (409, refusal("turn_changed")), (422, refusal("invalid_answer", reason: "unknown_option"))].enumerated() {
        #expect(store.begin(device: "d", key: "\(n)", method: "POST", path: "/p", body: Data(), now: 1) == .run)
        store.finish(device: "d", key: "\(n)", status: status, contentType: nil, body: refused)
        #expect(store.begin(device: "d", key: "\(n)", method: "POST", path: "/p", body: Data(), now: 1) == .replay(status: status, contentType: nil, body: refused))
    }
}
