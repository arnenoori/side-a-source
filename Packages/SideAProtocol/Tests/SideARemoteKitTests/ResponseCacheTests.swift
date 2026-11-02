import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import Testing

/// A Mac that tags each body the way L2's server does and answers a matching `If-None-Match` with an empty 304.
private func taggingMac(_ body: @escaping @Sendable (URLRequest) -> Data) -> FakeMac {
    let mac = FakeMac()
    mac.respond { request in
        let data = body(request)
        let etag = "\"\(data.count)-\(data.hashValue)\""
        if request.value(forHTTPHeaderField: "If-None-Match") == etag { return .init(status: 304, headers: ["ETag": etag]) }
        return .init(body: data, headers: ["ETag": etag])
    }
    return mac
}

@Test func aSecondReadSendsTheTagAndA304ReusesTheBody() async throws {
    let body = try Fixtures.data("OptionsList.basic")
    let mac = taggingMac { _ in body }
    let client = RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_token"), transport: mac, cache: ResponseCache())
    let first = try await client.options()
    let second = try await client.options()
    let served = try JSONDecoder().decode(OptionsList.self, from: body)
    #expect(first == second && first == served)
    #expect(mac.calls.count == 2)
    #expect(mac.calls[0].value(forHTTPHeaderField: "If-None-Match") == nil)
    #expect(mac.calls[1].value(forHTTPHeaderField: "If-None-Match") != nil)
}

@Test func aChangedBodyReplacesTheCachedOne() async throws {
    let bodies = [try Fixtures.data("OptionsList.basic"), json(OptionsList(agents: []))]
    let served = Counter()
    let mac = taggingMac { _ in bodies[min(served.next(), 1)] }
    let client = RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_token"), transport: mac, cache: ResponseCache())
    _ = try await client.options()
    let changed = try await client.options()
    #expect(changed == OptionsList(agents: []))
    let again = try await client.options()
    #expect(again == changed)
    #expect(mac.calls.last?.value(forHTTPHeaderField: "If-None-Match") != nil)
}

@Test func onlyTheTaggedReadsAreCachedAndEachQueryIsItsOwnEntry() async throws {
    let cache = ResponseCache()
    let page = try Fixtures.data("HistoryPage.pinned")
    let mac = taggingMac { _ in page }
    let client = RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_token"), transport: mac, cache: cache)
    _ = try await client.history()
    _ = try await client.history(archived: true)
    #expect(cache.count == 2)
    #expect(mac.calls.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == nil })
    _ = try await client.get("/v1/autopilot", as: AnyDecodable.self)
    #expect(cache.count == 2)
}

@Test func anotherTokenOrMacNeverSeesTheEntryAndForgetDropsIt() async throws {
    let cache = ResponseCache()
    let body = try Fixtures.data("OptionsList.basic")
    let mac = taggingMac { _ in body }
    _ = try await RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_token"), transport: mac, cache: cache).options()
    _ = try await RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_other"), transport: mac, cache: cache).options()
    #expect(mac.calls[1].value(forHTTPHeaderField: "If-None-Match") == nil)
    let other = Endpoint(macID: "mac2", baseURL: endpoint.baseURL, serverKeyHash: "pin", name: "Mini")
    _ = try await RemoteClient(endpoint: other, credentials: Keys(token: "sa1_token"), transport: mac, cache: cache).options()
    #expect(mac.calls[2].value(forHTTPHeaderField: "If-None-Match") == nil)
    #expect(cache.count == 3)
    cache.forget(macID: "mac1")
    #expect(cache.count == 1)
}

@Test func a401DropsTheMacsEntries() async throws {
    let cache = ResponseCache()
    let body = try Fixtures.data("OptionsList.basic")
    let mac = FakeMac()
    mac.respond { request in
        if request.url?.path == "/v1/projects" {
            return .init(status: 401, body: Data(#"{"error":{"code":"unauthorized","message":"Pair again.","retryable":false}}"#.utf8))
        }
        return .init(body: body, headers: ["ETag": "\"a\""])
    }
    let client = RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_token"), transport: mac, cache: cache)
    _ = try await client.options()
    #expect(cache.count == 1)
    await #expect(throws: RemoteFailure.self) { try await client.projects() }
    #expect(cache.count == 0)
}

@Test func aBodyWithoutATagLeavesNothingCached() async throws {
    let cache = ResponseCache()
    let body = try Fixtures.data("OptionsList.basic")
    let tagged = Counter()
    let mac = FakeMac()
    mac.respond { _ in tagged.next() == 0 ? .init(body: body, headers: ["ETag": "\"a\""]) : .init(body: body) }
    let client = RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_token"), transport: mac, cache: cache)
    _ = try await client.options()
    _ = try await client.options()
    #expect(cache.count == 0)
    _ = try await client.options()
    #expect(mac.calls.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
}

@Test func theCacheKeepsAtMostItsLimitOldestOut() {
    let cache = ResponseCache(limit: 2)
    for path in ["/v1/state", "/v1/sessions", "/v1/projects"] {
        var request = URLRequest(url: URL(string: "https://mac.local\(path)")!)
        request.httpMethod = "GET"
        cache.store(ResponseCache.key(macID: "mac1", request)!, etag: "\"x\"", body: Data())
    }
    #expect(cache.count == 2)
    var state = URLRequest(url: URL(string: "https://mac.local/v1/state")!)
    state.httpMethod = "GET"
    #expect(cache.entry(ResponseCache.key(macID: "mac1", state)!) == nil)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

private struct AnyDecodable: Decodable { init(from decoder: any Decoder) throws {} }
