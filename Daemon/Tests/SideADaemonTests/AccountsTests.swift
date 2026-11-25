import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SideACore
import SideAProtocol
import Testing
@testable import SideADaemonKit

private func login(in folder: URL, token: String = "tok-1", expiresAt: Double, email: String? = "me@example.com", plan: String = "max") throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let credentials: [String: Any] = ["claudeAiOauth": ["accessToken": token, "refreshToken": "r", "expiresAt": expiresAt, "subscriptionType": plan, "rateLimitTier": "default_claude_max_5x"]]
    try JSONSerialization.data(withJSONObject: credentials).write(to: folder.appendingPathComponent(".credentials.json"))
    if let email {
        try JSONSerialization.data(withJSONObject: ["oauthAccount": ["emailAddress": email]]).write(to: folder.appendingPathComponent(".claude.json"))
    }
}

private var reading: [String: Any] { [
    "five_hour": ["utilization": 42.5, "resets_at": "2026-11-24T20:00:00Z"],
    "seven_day": ["utilization": 71, "resets_at": 1_795_900_000],
    "limits": [["kind": "weekly_scoped", "scope": ["model": ["display_name": "Fable"]], "percent": 96, "resets_at": "2026-11-27T00:00:00Z"]],
    "spend": ["enabled": true, "used": ["amount_minor": 1250, "exponent": 2, "currency": "USD"], "limit": ["amount_minor": 5000, "exponent": 2]],
] }

private func answering(_ object: [String: Any], status: Int = 200, seen: LockedBox<[URLRequest]> = LockedBox([])) -> UsageReader {
    var reader = UsageReader(url: URL(string: "https://usage.test/api/oauth/usage")!)
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    reader.fetch = { request in
        seen.update { $0.append(request) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    return reader
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func update(_ change: (inout T) -> Void) { lock.lock(); change(&value); lock.unlock() }
    var current: T { lock.lock(); defer { lock.unlock() }; return value }
}

@Test func accountsGetAFolderEachAndAreListedFromThere() throws {
    let state = try temporaryDirectory("acc"), home = try temporaryDirectory("home")
    defer { try? FileManager.default.removeItem(at: state); try? FileManager.default.removeItem(at: home) }
    let book = AccountBook(state: state, home: home)
    let work = try book.add("Work Max")
    #expect(work.id == "work-max" && work.configDir.hasPrefix(home.path) && FileManager.default.fileExists(atPath: work.configDir))
    let mode = try FileManager.default.attributesOfItem(atPath: work.configDir)[.posixPermissions] as? Int
    #expect(mode == 0o700)
    #expect(throws: AccountBook.Failure.exists("work max")) { try book.add("work max") }
    // The login the machine already has is adopted where it is, not copied.
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    let main = try book.adopt("Main")
    #expect(main.configDir == home.appendingPathComponent(".claude").path)
    #expect(book.load().map(\.name) == ["Work Max", "Main"])
    let stored = try FileManager.default.attributesOfItem(atPath: book.file.path)[.posixPermissions] as? Int
    #expect(stored == 0o600)
    try book.remove("work-max")
    #expect(book.load().map(\.name) == ["Main"] && FileManager.default.fileExists(atPath: work.configDir))
}

@Test func theLimitsOfASignedInAccountAreReadFromItsOwnLoginFile() async throws {
    let state = try temporaryDirectory("acc"), home = try temporaryDirectory("home")
    defer { try? FileManager.default.removeItem(at: state); try? FileManager.default.removeItem(at: home) }
    let book = AccountBook(state: state, home: home)
    let work = try book.add("Work")
    let now = Date().timeIntervalSince1970
    try login(in: URL(fileURLWithPath: work.configDir), token: "secret-token", expiresAt: (now + 3_600) * 1000)
    let seen = LockedBox<[URLRequest]>([])
    let service = AccountsService(book: book, reader: answering(reading, seen: seen))
    let accounts = await service.list(refresh: true, now: now)
    let account = try #require(accounts.first)
    #expect(account.ready && account.email == "me@example.com" && account.issue == nil)
    let usage = try #require(account.usage)
    #expect(usage.fiveHour?.percent == 42.5 && usage.weekly?.percent == 71 && usage.capacity == 5)
    #expect(usage.modelLimits.map(\.label) == ["Weekly Fable"] && usage.extra?.used == 12.5 && usage.extra?.limit == 50)
    // The token goes out only as this account's own bearer, to the one URL.
    let request = try #require(seen.current.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token" && request.url?.host == "usage.test")
    #expect(seen.current.count == 1)
    // A second read inside the interval asks nobody.
    _ = await service.list(now: now + 5)
    #expect(seen.current.count == 1)
}

@Test func anExpiredOrMissingLoginIsSaidSoAndNothingIsSent() async throws {
    let state = try temporaryDirectory("acc"), home = try temporaryDirectory("home")
    defer { try? FileManager.default.removeItem(at: state); try? FileManager.default.removeItem(at: home) }
    let book = AccountBook(state: state, home: home)
    let empty = try book.add("New"), old = try book.add("Old")
    let now = Date().timeIntervalSince1970
    try login(in: URL(fileURLWithPath: old.configDir), expiresAt: (now - 10) * 1000)
    let seen = LockedBox<[URLRequest]>([])
    let accounts = await AccountsService(book: book, reader: answering(reading, seen: seen)).list(refresh: true, now: now)
    #expect(accounts.first { $0.id == empty.id }?.issue?.kind == .signedOut)
    #expect(accounts.first { $0.id == old.id }?.issue?.kind == .signIn && accounts.allSatisfy { !$0.ready })
    #expect(seen.current.isEmpty)
}

@Test func aRejectedTokenAndAnOfflineServerBothLeaveTheLastReadingMarkedStale() async throws {
    let state = try temporaryDirectory("acc"), home = try temporaryDirectory("home")
    defer { try? FileManager.default.removeItem(at: state); try? FileManager.default.removeItem(at: home) }
    let book = AccountBook(state: state, home: home)
    let account = try book.add("Work")
    let now = Date().timeIntervalSince1970
    try login(in: URL(fileURLWithPath: account.configDir), expiresAt: (now + 3_600) * 1000)
    let mode = LockedBox<Int>(200)
    let good = try JSONSerialization.data(withJSONObject: reading)
    var reader = UsageReader(url: URL(string: "https://usage.test/u")!)
    reader.fetch = { request in
        let status = mode.current
        if status == 0 { throw URLError(.notConnectedToInternet) }
        let body = status == 200 ? good : Data("{}".utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    let service = AccountsService(book: book, reader: reader, every: 0)
    #expect(await service.list(now: now).first?.usage?.stale == false)
    mode.update { $0 = 401 }
    var rejected = try #require(await service.list(now: now + 1).first)
    #expect(rejected.issue?.kind == .signIn && rejected.usage?.stale == true && !rejected.ready)
    mode.update { $0 = 0 }
    rejected = try #require(await service.list(now: now + 2).first)
    #expect(rejected.issue?.kind == .offline && rejected.usage?.stale == true)
}

@Test func theSelectorDecidesWhichVariableCarriesAnAccountsFolder() async throws {
    let state = try temporaryDirectory("acc"), home = try temporaryDirectory("home")
    defer { try? FileManager.default.removeItem(at: state); try? FileManager.default.removeItem(at: home) }
    let book = AccountBook(state: state, home: home)
    let account = try book.add("Work")
    #expect(await AccountsService(book: book).environment(for: account.id) == ["CLAUDE_CONFIG_DIR": account.configDir])
    #expect(await AccountsService(book: book, selector: .secureStorage).environment(for: account.id) == ["CLAUDE_SECURESTORAGE_CONFIG_DIR": account.configDir])
    #expect(await AccountsService(book: book).environment(for: "nobody") == nil)
    #expect(AccountSelector(option: "securestorage") == .secureStorage && AccountSelector(option: "nonsense") == nil)
}

@Test func theAccountsRouteAndTheSnapshotListThem() async throws {
    let home = try temporaryDirectory("home")
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = try temporaryDirectory("acc")
    defer { try? FileManager.default.removeItem(at: directory) }
    let book = AccountBook(state: directory, home: home)
    let account = try book.add("Work")
    try login(in: URL(fileURLWithPath: account.configDir), expiresAt: (Date().timeIntervalSince1970 + 3_600) * 1000)
    let services = AccountServices(accounts: AccountsService(book: book, reader: answering(reading)))
    var config = DaemonConfig(paths: DaemonPaths(state: directory))
    config.port = 0; config.discover = false; config.os = .linux
    let daemon = try SideADaemon(config: config, services: services)
    try await daemon.start()
    let phone = FakePhone()
    let pin = daemon.identity.spkiHash
    let paired = try await phone.pair(with: daemon, pin: pin)
    let connection = try await TestConnection.open(port: daemon.port, pin: pin)
    let headers = ["Authorization": "Bearer \(paired.token)"]
    let list = try await connection.request("GET", "/v1/accounts", headers: headers).json(AccountList.self)
    #expect(list.accounts.map(\.name) == ["Work"] && list.accounts.first?.usage?.fiveHour?.percent == 42.5)
    let state = try await connection.request("GET", "/v1/state", headers: headers).json(StateSnapshot.self)
    #expect(state.accounts.map(\.id) == ["work"])
    await connection.close()
    try await daemon.stop()
}
