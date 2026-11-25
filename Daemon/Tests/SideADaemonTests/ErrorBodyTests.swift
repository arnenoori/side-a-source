import Foundation
import SideAProtocol
import Testing
@testable import SideADaemonKit

/// The phone decodes every error as `ErrorBody` (`code` and `retryable` are not optional); a body it can't decode shows as a
/// bare "http_404". Every way the daemon refuses has to survive that.
@Test func everyErrorTheDaemonSendsDecodesAsTheProtocolsErrorBody() async throws {
    try await withDaemon { daemon, _ in
        let phone = FakePhone()
        let pin = daemon.identity.spkiHash
        let paired = try await phone.pair(with: daemon, pin: pin)
        let auth = ["Authorization": "Bearer \(paired.token)", "Content-Type": "application/json"]
        // A refusal may end the connection; the next question opens another, as the phone does.
        let held = LockedBox<TestConnection?>(nil)
        func ask(_ method: String, _ path: String, headers: [String: String] = [:], body: Data = Data(), host: String? = nil) async throws -> Answer {
            let existing = held.current
            let connection: TestConnection
            if let existing { connection = existing } else {
                connection = try await TestConnection.open(port: daemon.port, pin: pin)
                held.update { $0 = connection }
            }
            do {
                return try await connection.request(method, path, headers: headers, body: body, host: host)
            } catch {
                held.update { $0 = nil }
                let again = try await TestConnection.open(port: daemon.port, pin: pin)
                held.update { $0 = again }
                return try await again.request(method, path, headers: headers, body: body, host: host)
            }
        }
        let cases: [(String, Answer, Int, Bool)] = [
            ("unknown path", try await ask("GET", "/v1/nothing-here", headers: auth), 404, false),
            ("wrong method", try await ask("PUT", "/v1/hello", headers: auth), 405, false),
            ("no token", try await ask("GET", "/v1/state"), 401, false),
            ("bad body", try await ask("POST", "/v1/devices/push", headers: auth.merging(["Idempotency-Key": "e-1"]) { $1 }, body: Data("{".utf8)), 400, false),
            ("no idempotency key", try await ask("POST", "/v1/devices/push", headers: auth, body: Data("{}".utf8)), 400, false),
            ("no relay", try await ask("POST", "/v1/diagnostics/push", headers: auth.merging(["Idempotency-Key": "e-2"]) { $1 }, body: Data("{}".utf8)), 503, true),
            ("wrong host", try await ask("GET", "/v1/hello", headers: auth, host: "evil.example"), 0, false),
        ]
        for (name, answer, status, retryable) in cases {
            #expect(answer.status >= 400, "\(name) answered \(answer.status)")
            if status != 0 { #expect(answer.status == status, "\(name) answered \(answer.status)") }
            let decoded = try? answer.json(ErrorBody.self)
            #expect(decoded != nil, "\(name): \(String(decoding: answer.body, as: UTF8.self)) isn't an ErrorBody")
            #expect(decoded?.error.retryable == retryable, "\(name) retryable")
            #expect(decoded?.error.message.isEmpty == false, "\(name) has a message")
        }
        await held.current?.close()
    }
}
