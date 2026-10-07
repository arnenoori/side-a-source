import Foundation
import Testing
@testable import SideA

final class CaptureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { captured } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            capturedRequest.httpBody = body
        }
        Self.lock.withLock { Self.captured.append(capturedRequest) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"status\":\"Ok\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test @MainActor func appAnalyticsRequiresConsentAndHonorsRevocationAndDemoMode() async throws {
    let suite = "sidea-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CaptureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let analytics = AppAnalytics(defaults: defaults, token: "phc_fixture", session: session)
    #expect(!analytics.enabled)
    analytics.capture(.launched)
    analytics.capture(.accountConnected, provider: .claude)
    try await Task.sleep(for: .milliseconds(100))
    #expect(CaptureProtocol.requests.isEmpty)
    analytics.setEnabled(true)
    analytics.capture(.accountConnected, provider: .claude)
    for _ in 0..<30 where CaptureProtocol.requests.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    #expect(CaptureProtocol.requests.count == 1)
    #expect(CaptureProtocol.requests.first?.url?.absoluteString == "https://us.i.posthog.com/i/v0/e/")
    let body = try #require(CaptureProtocol.requests.first?.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(payload["event"] as? String == "account_connected")
    #expect(AppAnalytics(defaults: defaults, token: "phc_fixture", session: session).enabled)
    analytics.setEnabled(false)
    analytics.capture(.launched)
    let demo = AppAnalytics(defaults: defaults, allowed: false, token: "phc_fixture", session: session)
    demo.setEnabled(true); demo.capture(.accountConnected, provider: .claude)
    try await Task.sleep(for: .milliseconds(100))
    #expect(CaptureProtocol.requests.count == 1)
    #expect(!AppAnalytics(defaults: defaults, token: "phc_fixture", session: session).enabled)
    #expect(!demo.enabled)
    analytics.setEnabled(true)
    demo.setEnabled(false)
    #expect(AppAnalytics(defaults: defaults, token: "phc_fixture", session: session).enabled)
}
