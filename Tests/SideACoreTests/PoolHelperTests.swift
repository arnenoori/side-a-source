import Foundation
import Network
@testable import SideACore
import SideAProtocol
import Testing

@MainActor @Suite(.serialized)
struct PoolHelperTests {
    final class Clock: @unchecked Sendable { var now = 1_000_000.0 }

    func member(_ id: String, _ provider: AgentProvider = .claude, priority: AccountPriority? = nil, full: Bool = false, resets: Double = 0) -> PoolPlan.Member {
        let usage = full ? AccountUsage(windows: [UsageWindow(id: "seven_day", label: "Weekly", percent: 100, resetsAt: resets)]) : nil
        return PoolPlan.Member(id: id, provider: provider, name: id, priority: priority, usage: usage)
    }

    func plan(_ members: [PoolPlan.Member]) -> PoolPlan {
        PoolPlan(python: "/usr/bin/python3", bridge: "/nonexistent", members: members, full: 97)
    }

    @Test func picksByPriorityAndSkipsFullAccountsUntilTheirReset() {
        let clock = Clock()
        let decisions = PoolFallback(plan: plan([member("a", full: true, resets: clock.now + 3600), member("b"), member("c", priority: .first)]),
                                     root: URL(fileURLWithPath: "/"), log: { _ in }, clock: { clock.now })
        #expect(decisions.poolAccount(.claude, session: nil, excluding: []) == "c")
        #expect(decisions.poolAccount(.claude, session: nil, excluding: ["c"]) == "b")
        #expect(decisions.poolAccount(.claude, session: nil, excluding: ["c", "b"]) == nil)
        clock.now += 7200
        #expect(decisions.poolAccount(.claude, session: nil, excluding: ["c", "b"]) == "a")
        #expect(decisions.poolAccount(.codex, session: nil, excluding: []) == nil)
    }

    @Test func aConversationStaysOnItsAccountUntilItHitsItsLimit() {
        let clock = Clock()
        let decisions = PoolFallback(plan: plan([member("a"), member("b")]), root: URL(fileURLWithPath: "/"), log: { _ in }, clock: { clock.now })
        #expect(decisions.poolAccount(.claude, session: "s1", excluding: ["a"]) == "b")
        #expect(decisions.poolAccount(.claude, session: "s1", excluding: []) == "b")
        decisions.poolAnswered("b", status: 429, headers: HTTPHeaders([("retry-after", "120")]))
        #expect(decisions.poolAccount(.claude, session: "s1", excluding: []) == "a")
        clock.now += 121
        decisions.poolAnswered("a", status: 200, headers: HTTPHeaders())
        #expect(decisions.poolAccount(.claude, session: "s2", excluding: ["a"]) == "b")
    }

    @Test func tokensComeFromTheBridgeOnceAndAgainWhenRefused() async throws {
        let clock = Clock()
        final class Calls: @unchecked Sendable { var args: [[String]] = [] }
        let calls = Calls()
        let decisions = PoolFallback(plan: plan([member("a"), member("x", .codex)]), root: URL(fileURLWithPath: "/"), log: { _ in },
                                     bridge: { args in
                                         calls.args.append(args)
                                         return Data(#"{"accessToken":"t\#(calls.args.count)","accountId":"w","expiresAt":\#((clock.now + 3600) * 1000),"hash":"h"}"#.utf8)
                                     }, clock: { clock.now })
        #expect(try await decisions.poolToken("a", refused: false).token == "t1")
        #expect(try await decisions.poolToken("a", refused: false).token == "t1")
        #expect(try await decisions.poolToken("a", refused: true).token == "t2")
        #expect(try await decisions.poolToken("x", refused: false) == PoolCredential(token: "t3", accountID: "w"))
        #expect(calls.args == [["pool-token", "a"], ["pool-token", "a", "--refused", "h"], ["codex-pool-token", "x"]])
    }

    @Test func aLoginThatCantBeReadRests() {
        let clock = Clock()
        let decisions = PoolFallback(plan: plan([member("a")]), root: URL(fileURLWithPath: "/"), log: { _ in }, clock: { clock.now })
        decisions.poolTokenFailed("a", PoolBridge.Failure(stderr: "Side A[signin]: Sign in again"))
        #expect(decisions.poolAccount(.claude, session: nil, excluding: []) == nil)
        clock.now += 601
        #expect(decisions.poolAccount(.claude, session: nil, excluding: []) == "a")
    }

    @Test func aMessageThatOnlySaysSignInRestsBriefly() {
        let clock = Clock()
        let decisions = PoolFallback(plan: plan([member("a")]), root: URL(fileURLWithPath: "/"), log: { _ in }, clock: { clock.now })
        decisions.poolTokenFailed("a", PoolBridge.Failure(stderr: "Side A: Sign in Co's Keychain didn't answer; retrying later."))
        clock.now += 121
        #expect(decisions.poolAccount(.claude, session: nil, excluding: []) == "a")
    }

    final class Folder {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pool-helper-\(UUID().uuidString)")
        var files: PoolFiles { PoolFiles(root: root) }
        init() throws {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("runtime"), withIntermediateDirectories: true)
            try Data((String(repeating: "k", count: 64) + "\n").utf8).write(to: files.key)
        }
        func write(_ plan: PoolPlan) throws { try JSONEncoder().encode(plan).write(to: files.plan) }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    static func freePort() -> UInt16 {
        let listener = try! NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .global())
        ready.wait()
        return listener.port!.rawValue
    }

    static func answers(_ port: UInt16) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/side-a/health")!, timeoutInterval: 2)
        request.setValue("Bearer " + String(repeating: "k", count: 64), forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    @Test func theHelperServesWhileTheAppIsGoneAndHandsBackWhenItReturns() async throws {
        let folder = try Folder()
        try folder.write(plan([member("a")]))
        // A pid nothing runs as: the app quit.
        try Data("99999999\n".utf8).write(to: folder.files.app)
        let port = Self.freePort()
        let helper = PoolHelper(root: folder.root, version: "1.0", installed: { "1.0" }, logs: folder.root, port: port)
        #expect(await helper.tick() == nil)
        #expect(helper.serving)
        let pool = try String(contentsOf: folder.files.pool, encoding: .utf8)
        #expect(pool == "http://127.0.0.1:\(port) \(String(repeating: "k", count: 64)) \(ProcessInfo.processInfo.processIdentifier)\n")
        #expect(try FileManager.default.attributesOfItem(atPath: folder.files.pool.path)[.posixPermissions] as? Int == 0o600)
        #expect(await Self.answers(port))

        // The app is back: this test's own process stands in for it.
        try Data(PoolFiles.claim().utf8).write(to: folder.files.app)
        #expect(await helper.tick() == nil)
        #expect(!helper.serving)
        #expect(await !Self.answers(port))
    }

    @Test func theHelperWaitsWithoutAPlanAndRestartsOnceUpdatedAndIdle() async throws {
        let folder = try Folder()
        final class Disk: @unchecked Sendable { var version = "1.0" }
        let disk = Disk()
        let helper = PoolHelper(root: folder.root, version: "1.0", installed: { disk.version }, logs: folder.root, port: Self.freePort(), drain: 0)
        #expect(await helper.tick() == nil)
        try Data("garbage".utf8).write(to: folder.files.plan)
        #expect(await helper.tick() == nil)
        #expect(!helper.serving)
        disk.version = "1.1"
        #expect(await helper.tick() == 75)
    }

    @Test func anUpdatedHelperKeepsServingWhileTheAppIsGone() async throws {
        let folder = try Folder()
        try folder.write(plan([member("a")]))
        final class Disk: @unchecked Sendable { var version = "1.0" }
        let disk = Disk()
        let helper = PoolHelper(root: folder.root, version: "1.0", installed: { disk.version }, logs: folder.root, port: Self.freePort(), drain: 3600)
        #expect(await helper.tick() == nil)
        #expect(helper.serving)
        disk.version = "1.1"
        #expect(await helper.tick() == nil)
        #expect(helper.serving)
        // Handed back: replies still streaming get the drain before the restart.
        try Data(PoolFiles.claim().utf8).write(to: folder.files.app)
        #expect(await helper.tick() == nil)
        #expect(!helper.serving)
    }

    @Test func aClaimFromAProcessThatStartedAtAnotherTimeIsntTheApp() throws {
        let folder = try Folder()
        let pid = ProcessInfo.processInfo.processIdentifier
        try Data(PoolFiles.claim().utf8).write(to: folder.files.app)
        #expect(folder.files.appRunning)
        try Data("\(pid) 12345\n".utf8).write(to: folder.files.app)
        #expect(!folder.files.appRunning)
        try Data("99999999 0\n".utf8).write(to: folder.files.app)
        #expect(!folder.files.appRunning)
    }
}
