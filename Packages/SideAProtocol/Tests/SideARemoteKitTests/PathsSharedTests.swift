import Foundation
@testable import SideARemoteKit
import Testing

struct PathsSharedTests {
    struct NoCredentials: CredentialStore {
        func token(for macID: String) async throws -> String? { nil }
        func setToken(_ token: String?, for macID: String) async throws {}
    }

    func endpoint(_ macID: String) -> Endpoint {
        Endpoint(macID: macID, baseURL: URL(string: "https://127.0.0.1:9")!, serverKeyHash: "pin", name: macID)
    }

    @Test func eachMacHasItsOwnPathsUntilItIsForgotten() {
        let a = Paths.shared(for: endpoint("mac-a"), credentials: NoCredentials())
        let b = Paths.shared(for: endpoint("mac-b"), credentials: NoCredentials())
        #expect(a !== b)
        #expect(Paths.shared(for: endpoint("mac-a"), credentials: NoCredentials()) === a)
        Paths.forget(macID: "mac-a")
        #expect(Paths.shared(for: endpoint("mac-a"), credentials: NoCredentials()) !== a)
        #expect(Paths.shared(for: endpoint("mac-b"), credentials: NoCredentials()) === b)
        Paths.forget(macID: "mac-a"); Paths.forget(macID: "mac-b")
    }

    @Test func aClientHeldOverAnUnpairFindsNoPathAndStartsNothing() async {
        let paths = Paths.shared(for: endpoint("mac-c"), credentials: NoCredentials())
        let client = RemoteClient(endpoint: endpoint("mac-c"), credentials: NoCredentials(), transport: RoutedTransport(paths: paths))
        Paths.forget(macID: "mac-c")
        for _ in 0..<100 where await paths.path() != nil { await Task.yield() }
        #expect(await paths.path() == nil)
        await #expect(throws: URLError.self) { _ = try await client.send(try await client.request("GET", "/v1/hello")) }
    }
}
