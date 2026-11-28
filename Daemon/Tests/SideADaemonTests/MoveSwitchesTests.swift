import Foundation
import NIOCore
import NIOPosix
import SideACore
import SideAProtocol
import Testing
@testable import SideADaemonKit

private func object(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// A loopback port nothing listens on: bound, then closed again.
private func deadPort() async throws -> Int {
    let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
    let port = try #require(channel.localAddress?.port)
    try await channel.close()
    return port
}

extension MoveTests {
    @Test func aMoveGoesThroughTheRelayWhenTheOtherComputersAddressesDontAnswer() async throws {
        let stub = try StubRelay()
        defer { stub.shutdown() }
        var source = try Machine("build-box")
        var target = try Machine("spare-box")
        try source.signIn("you@example.com"); try target.signIn("you@example.com")
        target.relay = RelayConfig(url: stub.url)
        let folder = try await source.project()
        source.settings.projects = [folder.path]
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            let installID = try #require(b.daemon.relay?.installID)
            let unanswered = try await deadPort()
            // Its addresses answer nothing; its relay is the one way there.
            try await a.moves.links.update(b.machine.hostID) {
                $0.relay = RelayInfo(url: stub.url.absoluteString, installID: installID, keyID: "")
                $0.endpoints = Endpoints(tailnet: "127.0.0.1:\(unanswered)")
            }
            let computer = try #require(await a.moves.links.computer(b.machine.hostID))
            #expect(computer.route != nil)
            #expect(await eventually(30) { stub.connections >= 1 && stub.texts.contains { $0.contains("\"devices\"") && $0.contains(computer.deviceID) } })

            // A secret the relay doesn't know is refused there, and nothing reaches the other computer.
            var wrong = computer
            wrong.deviceSecret = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64URL
            await #expect(throws: PeerFailure.self) { try await LinkedPeer(wrong).state("mv-0123456789") }
            #expect(stub.phoneUpgrades == 0)

            let row = try await a.host(folder, prompt: "over the relay")
            let conversation = try #require(row.id)
            let state = try await a.moves.move(conversation, to: "spare-box")
            #expect(state.status == .live)
            let there = try #require(await b.running(conversation))
            #expect(try String(contentsOf: URL(fileURLWithPath: try #require(there.cwd)).appendingPathComponent("notes.txt"), encoding: .utf8) == "not committed\n")
            #expect(await a.running(conversation) == nil)
            // Every request was a stream of one socket to the relay, in the phone's role.
            #expect(stub.phoneUpgrades == 1)
            #expect(stub.fromPhones.filter { $0.kind == .open }.count >= 5)
            #expect(await a.moves.journal.all.first { $0.session == conversation }?.step == .away)
        }
    }

    @Test func aProjectsIgnoredEnvFilesGoWithAMoveOnlyWhenThatIsTurnedOn() async throws {
        var source = try Machine("build-box")
        let target = try Machine("spare-box")
        try source.signIn("you@example.com"); try target.signIn("you@example.com")
        let app = try await source.project("app"), api = try await source.project("api")
        for folder in [app, api] {
            try Data(".env\n".utf8).write(to: folder.appendingPathComponent(".gitignore"))
            try Data("TOKEN=made-up\n".utf8).write(to: folder.appendingPathComponent(".env"))
        }
        source.settings.projects = [app.path, api.path]
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            // Off, as it starts: the work goes, the .env file stays.
            let first = try #require(try await a.host(app, prompt: "without the env").id)
            #expect(try await a.moves.move(first, to: "spare-box").status == .live)
            let plain = URL(fileURLWithPath: try #require(await b.running(first)?.cwd))
            #expect(FileManager.default.fileExists(atPath: plain.appendingPathComponent("notes.txt").path))
            #expect(!FileManager.default.fileExists(atPath: plain.appendingPathComponent(".env").path))

            let set = try object(await a.service.control("config", ["key": "include-env", "value": "on"]))
            #expect(set["ok"] as? Bool == true)
            let second = try #require(try await a.host(api, prompt: "with the env").id)
            #expect(try await a.moves.move(second, to: "spare-box").status == .live)
            let landed = URL(fileURLWithPath: try #require(await b.running(second)?.cwd))
            #expect(try String(contentsOf: landed.appendingPathComponent(".env"), encoding: .utf8) == "TOKEN=made-up\n")
        }
    }

    @Test func aComputerNotAcceptingSessionsRefusesThemAndMoveAllSaysWhatStayed() async throws {
        var source = try Machine("build-box")
        let target = try Machine("spare-box")
        try source.signIn("you@example.com"); try target.signIn("you@example.com")
        let app = try await source.project("app"), api = try await source.project("api")
        source.settings.projects = [app.path, api.path]
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            let one = try #require(try await a.host(app, prompt: "first of two").id)
            let two = try #require(try await a.host(api, prompt: "second of two").id)

            #expect(await DaemonCLI.config(DaemonPaths(state: b.machine.state), ["accept-sessions", "off"]) == 0)
            let sentence = "spare-box isn't accepting sessions. Turn that on there with sidead config accept-sessions on."
            await #expect(throws: MoveFailure.refused(sentence)) { try await a.moves.move(one, to: "spare-box") }
            #expect(await a.running(one) != nil)
            #expect(await b.moves.journal.all.isEmpty)
            let stayed = try object(await a.service.control("move-all", ["computer": "spare-box"]))
            #expect(stayed["ok"] as? Bool == true)
            #expect((stayed["moved"] as? [String])?.isEmpty == true)
            #expect((stayed["stayed"] as? [[String: String]])?.map { $0["reason"] } == [sentence, sentence])

            #expect(await DaemonCLI.config(DaemonPaths(state: b.machine.state), ["accept-sessions", "on"]) == 0)
            let went = try object(await a.service.control("move-all", ["computer": "spare-box"]))
            #expect(went["ok"] as? Bool == true)
            #expect((went["moved"] as? [String])?.count == 2 && (went["stayed"] as? [[String: String]])?.isEmpty == true)
            for conversation in [one, two] {
                #expect(await b.running(conversation) != nil)
                #expect(await a.running(conversation) == nil)
            }
            let none = try object(await a.service.control("move-all", ["computer": "spare-box"]))
            #expect(none["ok"] as? Bool == false && none["error"] as? String == "No hosted session here has finished its turn.")
        }
    }

    @Test func runHereStartsAMoveWhoseOutcomeIsUnknownHereAgainWhenTheOtherComputerIsGone() async throws {
        var source = try Machine("build-box")
        let target = try Machine("spare-box")
        try source.signIn("you@example.com"); try target.signIn("you@example.com")
        let folder = try await source.project()
        source.settings.projects = [folder.path]
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            let conversation = try #require(try await a.host(folder, prompt: "run it here").id)
            await a.moves.set(peers: { StallingPeer(inner: LinkedPeer($0)) })
            await #expect(throws: MoveFailure.unknown(peer: "spare-box")) { try await a.moves.move(conversation, to: "spare-box") }
            let id = try #require(await a.moves.journal.all.first { $0.session == conversation }?.id)
            #expect(await a.moves.records().first { $0.id == id }?.state == .unknown)
            let other = try object(await a.service.control("run-here", ["move": "mv-0123456789"]))
            #expect(other["ok"] as? Bool == false)

            try await b.daemon.stop()
            await a.moves.set(peers: { LinkedPeer($0) })
            let answer = try object(await a.service.control("run-here", ["move": id]))
            #expect(answer["ok"] as? Bool == true && answer["conversation"] as? String == conversation)
            #expect(await a.moves.journal[id]?.step == .returned)
            #expect(await eventually(30) { await a.running(conversation) != nil })
            #expect(a.machine.resumes(conversation) == 1)
            let again = try object(await a.service.control("run-here", ["move": id]))
            #expect(again["ok"] as? Bool == false)
        }
    }

    @Test func runHereStartsNothingWhenTheOtherComputerSaysTheSessionRunsThere() async throws {
        var source = try Machine("build-box")
        let target = try Machine("spare-box")
        try source.signIn("you@example.com"); try target.signIn("you@example.com")
        let folder = try await source.project()
        source.settings.projects = [folder.path]
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            let conversation = try #require(try await a.host(folder, prompt: "it did start there").id)
            await a.moves.set(peers: { LosingPeer(inner: LinkedPeer($0)) })
            await #expect(throws: MoveFailure.unknown(peer: "spare-box")) { try await a.moves.move(conversation, to: "spare-box") }
            let id = try #require(await a.moves.journal.all.first { $0.session == conversation }?.id)
            #expect(await b.running(conversation) != nil)

            await a.moves.set(peers: { LinkedPeer($0) })
            let answer = try object(await a.service.control("run-here", ["move": id]))
            #expect(answer["ok"] as? Bool == false && answer["error"] as? String == "It's running on spare-box.")
            #expect(await a.moves.journal[id]?.step == .away)
            #expect(await a.running(conversation) == nil)
            #expect(a.machine.resumes(conversation) == 0)
        }
    }
}

@Test func theMoveCommandTakesAllRunHereAndYes() throws {
    let all = try #require(DaemonCLI.parse(["move", "--all", "spare-box"]))
    #expect(all.command == "move" && all.all && all.rest == ["spare-box"])
    let here = try #require(DaemonCLI.parse(["move", "--run-here", "mv-0123456789", "--yes"]))
    #expect(here.runHere && here.yes && here.rest == ["mv-0123456789"])
    let config = try #require(DaemonCLI.parse(["config", "include-env", "on"]))
    #expect(config.command == "config" && config.rest == ["include-env", "on"])
}

@Test func moveSettingsAreKeptInTheStateFolderAndOneThatCantBeReadTakesNothingIn() async throws {
    let directory = try temporaryDirectory("settings")
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = DaemonPaths(state: directory)
    let store = FileSecretStore(directory: directory)
    #expect(MoveSettings.load(store) == MoveSettings(accepts: true, includesEnv: false, standby: nil))
    #expect(await DaemonCLI.config(paths, ["include-env", "on"]) == 0)
    #expect(await DaemonCLI.config(paths, ["accept-sessions", "off"]) == 0)
    #expect(MoveSettings.load(store) == MoveSettings(accepts: false, includesEnv: true))
    let file = directory.appendingPathComponent("moves-settings.json")
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    #expect(await DaemonCLI.config(paths, ["include-env", "maybe"]) == 1)
    #expect(await DaemonCLI.config(paths, ["standby", "nowhere"]) == 1)
    #expect(await DaemonCLI.config(paths, ["colour", "on"]) == 2)
    #expect(MoveSettings.load(store) == MoveSettings(accepts: false, includesEnv: true))
    #expect(await DaemonCLI.config(paths, ["standby", "off"]) == 0)
    // A file it can't read: nothing comes in and nothing goes to a standby.
    try store.write("moves-settings.json", Data("{not json".utf8))
    #expect(MoveSettings.load(store) == MoveSettings(accepts: false, includesEnv: false, standby: nil))
}

@Test func aRelayPathNeedsAnHTTPSRelayOrOneOnThisMachineAndTheRelaysOwnIDs() throws {
    let id = Data(repeating: 1, count: 16).base64URL, secret = Data(repeating: 2, count: 32).base64URL
    func route(_ url: String, install: String = id, device: String = id, secret: String = secret) -> PeerTunnel.Route? {
        PeerTunnel.Route(relay: RelayInfo(url: url, installID: install, keyID: ""), deviceID: device, secret: secret)
    }
    #expect(route("https://relay.example.test")?.authorization == "Bearer d1.\(id).\(id).\(secret)")
    #expect(route("https://relay.example.test/base/")?.path == "/base/v1/tunnel/phone")
    #expect(route("http://127.0.0.1:8787")?.path == "/v1/tunnel/phone")
    #expect(route("http://relay.example.test") == nil)
    #expect(route("https://relay.example.test", install: "short") == nil)
    #expect(route("https://relay.example.test", device: id + "/") == nil)
    #expect(route("https://relay.example.test", secret: Data(repeating: 2, count: 16).base64URL) == nil)
    #expect(PeerTunnel.Route(relay: nil, deviceID: id, secret: secret) == nil)
}
