import Foundation
import SideACore
import SideAProtocol
import Testing
@testable import SideADaemonKit

/// The processes holding a listening TCP socket on `port`: `lsof` on a Mac, `/proc` on Linux; nil where neither can say.
func listeners(_ port: Int) async -> Set<Int32>? {
    #if os(Linux)
    var inodes: Set<String> = []
    for table in ["/proc/net/tcp", "/proc/net/tcp6"] {
        let text = (try? String(contentsOfFile: table, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            // local address, state 0A (listening), inode
            guard fields.count > 9, fields[3] == "0A", let local = fields[1].split(separator: ":").last, Int(local, radix: 16) == port else { continue }
            inodes.insert(String(fields[9]))
        }
    }
    guard !inodes.isEmpty else { return [] }
    var holders: Set<Int32> = []
    for pid in (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? [] {
        guard let number = Int32(pid) else { continue }
        for fd in (try? FileManager.default.contentsOfDirectory(atPath: "/proc/\(pid)/fd")) ?? [] {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/fd/\(fd)") else { continue }
            if target.hasPrefix("socket:["), inodes.contains(String(target.dropFirst(8).dropLast())) { holders.insert(number) }
        }
    }
    return holders
    #else
    guard let lsof = Run.which("lsof", extra: ["/usr/sbin"]) else { return nil }
    let result = await Run.process(lsof, ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"], timeout: 20)
    // 1 is "nothing found"; anything else is lsof failing.
    guard result.status == 0 || (result.status == 1 && result.output.isEmpty) else { return nil }
    return Set(result.output.split(separator: "\n").compactMap { Int32($0) })
    #endif
}

extension MoveTests {
    @Test func aHostedSessionThatOutlivesTheDaemonHoldsNoneOfItsSocketsSoItStartsAgainOnTheSamePort() async throws {
        let machine = try Machine("build-box")
        try machine.signIn("you@example.com")
        let folder = try await machine.project()
        try await withComputers([machine]) { computers in
            let first = computers[0]
            let port = first.daemon.port
            let row = try await first.host(folder, prompt: "outlive the daemon")
            let name = try #require(row.hosted)
            // While it runs, the listener is the daemon's alone: not the tmux server's, the agent's or the bridge's.
            if let holders = await listeners(port) { #expect(holders == [getpid()], "\(holders)") }
            try await first.daemon.stop()
            // The session goes on without it.
            #expect(await first.engine.tmux.list().contains { $0.name == name && !$0.dead })
            if let holders = await listeners(port) { #expect(holders.isEmpty, "\(holders)") }

            let again = try await start(machine, port: port)
            #expect(again.daemon.port == port)
            let connection = try await TestConnection.open(port: port, pin: again.daemon.identity.spkiHash)
            #expect(try await connection.request("GET", "/v1/hello").status == 200)
            await connection.close()
            #expect(await again.running(try #require(row.id)) != nil)
            try await again.daemon.stop()
        }
    }
}

/// The `a=` field of a pairing link.
private func linkAddress(_ link: String) -> String? {
    let fields = link.split(separator: "#").last?.split(separator: "&") ?? []
    return fields.first { $0.hasPrefix("a=") }.map { String($0.dropFirst(2)).removingPercentEncoding ?? String($0.dropFirst(2)) }
}

@Test func withDiscoveryOffAPhoneOrAMacIsToldTheAddressesTheDaemonListensOn() throws {
    var config = DaemonConfig(paths: DaemonPaths(state: try temporaryDirectory("plan")))
    config.discover = false
    config.listen = ["192.0.2.10"]
    var plan = SideADaemon.plan(config)
    #expect(plan.listen == ["192.0.2.10"])
    #expect(plan.addresses == RemoteAddresses(lan: ["192.0.2.10"]))
    config.listen = ["100.101.102.103", "192.0.2.10"]
    plan = SideADaemon.plan(config)
    #expect(plan.addresses == RemoteAddresses(tailnet: ["100.101.102.103"], lan: ["192.0.2.10"]))
    // Loopback, or every address, says nothing a phone could dial: it is told loopback, as before.
    for listen in [[], ["127.0.0.1"], ["0.0.0.0"]] {
        config.listen = listen
        #expect(SideADaemon.plan(config).addresses == RemoteAddresses(), "\(listen)")
    }
}

@Test func aPairingLinkFromADaemonListeningOnOneAddressNamesThatAddress() async throws {
    // An address this machine has, so the daemon can listen on it; loopback when it has none.
    let found = RemoteAddresses.current()
    let address = found.lan.first ?? found.tailnet.first { !$0.contains(":") }
    let directory = try temporaryDirectory("link")
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = DaemonConfig(paths: DaemonPaths(state: directory))
    config.port = 0
    config.discover = false
    config.os = .linux
    config.listen = [address ?? "127.0.0.1"]
    let daemon = try SideADaemon(config: config)
    try await daemon.start()
    let link = daemon.link(code: "123456")
    let endpoints = daemon.hello(paired: true).endpoints
    let expected = "\(address ?? "127.0.0.1"):\(daemon.port)"
    try await daemon.stop()
    #expect(linkAddress(link) == expected, "\(link)")
    #expect(endpoints.tailnet == expected)
}
