import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

@MainActor private func working() throws -> AccountStore {
    let store = AccountStore(demo: true, root: FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))"))
    store.island.installed[.claude] = true
    let object: [String: Any] = ["pid": 941, "id": "s-busy", "status": "busy", "agent": "claude", "cwd": "/tmp/app", "started": 1_700_000_000]
    store.sessions.live.append(try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: object)))
    return store
}

@MainActor @Test func aQueuedReplyCanBeSeenRewordedAndRemoved() async throws {
    let store = try working()
    let commands = SessionCommands(store: store)
    for text in ["run the tests", "then commit", "run the tests"] {
        #expect(try await commands.reply("s-busy", .init(text: text, mode: .followUp)).delivery == .queued)
    }
    var queued = try #require(WireBuilders.session(store.sessions.live[0], store: store, finished: []).queued)
    #expect(queued.map(\.text) == ["run the tests", "then commit", "run the tests"] && Set(queued.map(\.id)).count == 3)

    var edit = SessionCommands.Message(text: "then commit and push", mode: .followUp)
    edit.replaces = queued[1].id
    #expect(try await commands.reply("s-busy", edit).delivery == .queued)
    #expect(store.island.waiting("s-busy").map(\.text) == ["run the tests", "then commit and push", "run the tests"])
    await #expect(throws: SessionCommands.Failure.queueChanged) { try await commands.reply("s-busy", edit) }

    queued = store.island.waiting("s-busy")
    #expect(store.island.removeQueued("s-busy", id: queued[0].id) && !store.island.removeQueued("s-busy", id: queued[0].id + "x"))
    #expect(store.island.waiting("s-busy").map(\.text) == ["then commit and push", "run the tests"])
    #expect(store.island.waiting("s-busy").map(\.id) == [queued[1].id, queued[0].id])
    #expect(!store.island.removeQueued("s-busy", id: queued[2].id))
    #expect(store.island.removeQueued("s-busy", id: queued[1].id) && store.island.removeQueued("s-busy", id: queued[0].id))
    #expect(WireBuilders.session(store.sessions.live[0], store: store, finished: []).queued == nil)
    #expect(RemoteController.capabilities.isSuperset(of: [.repliesQueue, .files]))
}

@Test func aFoldersFilesAreListedWithoutWhatGitIgnores() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sa-files-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: folder) }
    for path in ["Sources/App/Main.swift", "Sources/App/odd name's.swift", "node_modules/pkg/index.js", "build/out.o", ".env", "README.md"] {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }
    #expect(Set(FileMentions.walk(folder.path)) == ["Sources/App/Main.swift", "Sources/App/odd name's.swift", "README.md"])
    #expect(Set(await FileMentions.list(folder.path)) == ["Sources/App/Main.swift", "Sources/App/odd name's.swift", "README.md"])

    try Data("node_modules/\n.env\n".utf8).write(to: folder.appendingPathComponent(".gitignore"))
    #expect(await ProcessRunner.run("/usr/bin/git", ["-C", folder.path, "init", "-q"], timeout: 10).status == 0)
    let listed = Set(await FileMentions.list(folder.path))
    #expect(listed == ["Sources/App/Main.swift", "Sources/App/odd name's.swift", "README.md", "build/out.o", ".gitignore"])
    #expect(await FileMentions().matches("main", in: folder.path) == ["Sources/App/Main.swift"])
}

@MainActor private func call(_ store: AccountStore, _ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> (status: Int, body: [String: Any]) {
    let parts = URLComponents(string: "/" + path)
    let query = Dictionary((parts?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    let request = HTTPRequest(method: method, target: "/" + path, path: (parts?.path ?? path).split(separator: "/").map(String.init), query: query,
                              headers: HTTPHeaders([]), body: try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data())
    let response = await RemoteRoutes.route(request, RemoteServer.Caller(device: "d1", connection: 1), store.remote)
    return (response.status, response.body.isEmpty ? [:] : try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any]))
}

private func code(_ object: [String: Any]) -> String? { (object["error"] as? [String: Any])?["code"] as? String }

@MainActor @Test func aPhoneEditsTheQueueAndAsksForFiles() async throws {
    let store = try working()
    store.remote.confirmCheck = { _, _, _, _, _ in nil }
    for text in ["first", "second"] {
        let sent = try await call(store, "POST", "v1/sessions/s-busy/reply", ["text": text, "mode": "followUp", "attachments": []])
        #expect(sent.status == 200 && sent.body["delivery"] as? String == "queued")
    }
    let ids = store.island.waiting("s-busy").map(\.id)
    #expect(ids.count == 2)
    var answer = try await call(store, "POST", "v1/sessions/s-busy/reply", ["text": "first, carefully", "mode": "followUp", "attachments": [], "replaces": ids[0]])
    #expect(answer.status == 200 && store.island.waiting("s-busy").map(\.text) == ["first, carefully", "second"])
    answer = try await call(store, "POST", "v1/sessions/s-busy/reply", ["text": "again", "mode": "followUp", "attachments": [], "replaces": ids[0]])
    #expect(answer.status == 409 && code(answer.body) == "queue_changed" && store.island.waiting("s-busy").count == 2)
    answer = try await call(store, "DELETE", "v1/sessions/s-busy/queue/\(ids[1])")
    #expect(answer.status == 204 && store.island.waiting("s-busy").map(\.text) == ["first, carefully"])
    answer = try await call(store, "DELETE", "v1/sessions/s-busy/queue/\(ids[1])")
    #expect(answer.status == 409 && code(answer.body) == "queue_changed")
    #expect(try await call(store, "DELETE", "v1/sessions/nobody/queue/\(ids[1])").status == 404)
    #expect(try await call(store, "GET", "v1/sessions/nobody/files?q=a").status == 404)
}
