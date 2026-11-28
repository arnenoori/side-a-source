import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import SideASessionKit
import Testing

@MainActor private func store(_ sessions: [[String: Any]]) throws -> AccountStore {
    let store = AccountStore(demo: true)
    store.island.installed[.claude] = true
    for object in sessions {
        var object = object
        object["cwd"] = "/tmp/app"; object["started"] = 1_700_000_000
        store.sessions.live.append(try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    return store
}

@MainActor @Test func aPastedPhotoGoesWithTheReplyAsItsPath() async throws {
    let store = try store([["pid": 921, "id": "s-work", "status": "busy", "agent": "claude"]])
    let image = NSImage(size: NSSize(width: 4, height: 4))
    image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
    let tiff = try #require(image.tiffRepresentation)
    let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    let sessions = store.sessions
    sessions.attach([png, Data("not a photo".utf8)], to: "s-work")
    for _ in 0..<50 where sessions.attachments["s-work"] == nil { try await Task.sleep(for: .milliseconds(20)) }
    let photo = try #require(sessions.attachments["s-work"]?.first)
    #expect(sessions.attachments["s-work"]?.count == 1 && sessions.error != nil)
    #expect(photo.path.hasPrefix(RemoteUploads.folder(store.root).path))

    sessions.drafts["s-work"] = "look at this"
    sessions.compose("s-work", how: .now)
    for _ in 0..<50 where sessions.outcomes["s-work"] == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(sessions.outcomes["s-work"]?.result == .sent(.note))
    let mail = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: store.root.appendingPathComponent("runtime/mail/921.json")))
    #expect(mail["text"] == "look at this\n\(photo.path)")
    #expect(sessions.attachments["s-work"] == nil && sessions.drafts["s-work"] == "")
}

@Test func suggestionsFollowTheWordAtTheCaret() throws {
    let options = [("/review", "Review"), ("/clear", "Clear"), ("/prompts:release", "Release"), ("$ship", "Ship"), ("$imagegen", "Images")]
        .map { CommandSuggestions.Option(id: $0.0, label: $0.1) }
    #expect(CommandSuggestions.word(in: "please /re", caret: 10, agent: .claude)?.word == "/re")
    #expect(CommandSuggestions.word(in: "please /re", caret: 6, agent: .claude) == nil)
    #expect(CommandSuggestions.word(in: "$sh", caret: 3, agent: .claude) == nil)
    #expect(CommandSuggestions.word(in: "$sh", caret: 3, agent: .codex)?.word == "$sh")
    #expect(CommandSuggestions.matches("/re", in: options).map(\.id) == ["/review", "/prompts:release"])
    #expect(CommandSuggestions.matches("$", in: options).map(\.id) == ["$ship", "$imagegen"])
    let found = try #require(CommandSuggestions.word(in: "/re then", caret: 3, agent: .claude))
    #expect(CommandSuggestions.apply(options[0], to: "/re then", at: found.range).text == "/review then")
    #expect(CommandSuggestions.apply(options[0], to: "/re", at: NSRange(location: 0, length: 3)).text == "/review ")
}

@MainActor @Test func theIslandTakesAModeOnlyWhereTheRequestOffersOne() throws {
    let store = AccountStore(demo: true)
    let island = store.island
    func pending(_ tool: String, _ input: [String: Any]) throws -> Island.Pending {
        let data = try JSONSerialization.data(withJSONObject: ["v": 1, "agent": "claude", "pid": 941, "slot": "mac", "request": [
            "session_id": "s-mode", "tool_name": tool, "cwd": "/tmp/app", "tool_input": input,
        ]])
        let item = Island.Pending(connection: nil, request: try #require(IslandRequest(message: data)), title: "app", account: nil, handBackAt: nil)
        island.pending.append(item)
        return item
    }
    let edit = try pending("Edit", ["file_path": "/tmp/app/README.md", "old_string": "a", "new_string": "b"])
    guard case .done(let resolution) = island.remoteAnswer(edit.id.uuidString, .allow(confirmDestructive: false), mode: .acceptEdits,
                                                          device: "d1", name: "Pocket", proven: .unlock) else {
        Issue.record("Allow and switch mode was refused"); return
    }
    #expect(resolution.answer == .allow)

    let rm = try pending("Bash", ["command": "rm -rf build"])
    #expect(!island.respond(.allowMode("acceptEdits"), rm.id, by: .remote(device: "d1", name: "Pocket")))
    let plan = try pending("ExitPlanMode", ["plan": "Do it"])
    #expect(!island.respond(.allowMode("acceptEdits"), plan.id, confirmed: true))
    #expect(island.pending.map(\.id) == [rm.id, plan.id])
}

@MainActor @Test func theSettingsChipReadsThePhonesRow() throws {
    let store = try store([["pid": 951, "id": "s-set", "status": "busy", "agent": "claude"]])
    store.sessions.live[0].model = "claude-opus-5-5"
    store.sessions.live[0].effort = "high"
    store.sessions.live[0].mode = "default"
    store.sessions.live[0].contextPercent = 41.6
    let row = WireBuilders.session(store.sessions.live[0], store: store, finished: [])
    #expect(SettingsChip.summary(row) == "\(ModelName.short("claude-opus-5-5")) · High · 42% context")
    store.sessions.live[0].effort = "xhigh"
    #expect(SettingsChip.summary(WireBuilders.session(store.sessions.live[0], store: store, finished: [])) == "\(ModelName.short("claude-opus-5-5")) · Extra high · 42% context")
    store.sessions.live[0].backgroundTasks = (1...2).map { n in LiveSession.BackgroundTask(id: "t\(n)", type: "bash", status: "running", description: nil) }
    #expect(SettingsChip.summary(WireBuilders.session(store.sessions.live[0], store: store, finished: []))?.hasSuffix("42% context · 2 running") == true)
    store.sessions.live[0].backgroundTasks = [LiveSession.BackgroundTask(id: "t3", type: "bash", status: "completed", description: nil)]
    #expect(SettingsChip.summary(WireBuilders.session(store.sessions.live[0], store: store, finished: []))?.hasSuffix("42% context") == true)
    #expect([Effort.auto, .low, .xhigh, .max, Effort(rawValue: "turbo")].map(\.title) == ["Auto", "Low", "Extra high", "Max", "Turbo"])
    #expect(!SettingsChip.changeable(row))
    store.sessions.live[0].model = nil; store.sessions.live[0].effort = nil; store.sessions.live[0].mode = nil; store.sessions.live[0].contextPercent = nil
    #expect(SettingsChip.summary(WireBuilders.session(store.sessions.live[0], store: store, finished: [])) == nil)
}

@MainActor @Test func settingsGoOnlyWhereADriverCanTakeThem() async throws {
    let store = try store([["pid": 921, "id": "s-host", "status": "busy", "agent": "claude", "hosted": "sa-app-1"],
                           ["pid": 922, "id": "s-plain", "status": "idle", "agent": "claude"],
                           ["pid": 923, "id": "c-plain", "status": "idle", "agent": "codex"]])
    let commands = SessionCommands(store: store)
    store.remote.typer.staged = [:]
    func failure(_ id: String, _ change: SettingsChange) async -> SessionCommands.Failure? {
        do { _ = try await commands.settings(id, change); return nil } catch { return error }
    }
    func compactFailure(_ id: String) async -> SessionCommands.Failure? {
        do { try await commands.compact(id); return nil } catch { return error }
    }
    var refused = await failure("s-plain", SettingsChange(model: "sonnet"))
    #expect(refused?.status == 409 && refused?.code == .cannotDeliver && refused?.message == "Changing settings needs a session Side A hosts.")
    refused = await failure("c-plain", SettingsChange(mode: .plan))
    #expect(refused?.code == .cannotDeliver)
    refused = await failure("s-host", SettingsChange(fast: true))
    #expect(refused?.status == 422 && refused?.message == SessionCommands.fastRefusal)
    refused = await failure("s-host", SettingsChange(effort: .auto))
    #expect(refused?.status == 422)
    refused = await failure("s-host", SettingsChange(model: "sonnet"))
    #expect(refused?.status == 409 && refused?.message == "Claude is working. Try when it's idle.")
    #expect(await failure("gone", SettingsChange(model: "sonnet")) == .noSession)

    let host = try #require(store.sessions.live.first { $0.pid == 921 })
    var row = SessionCommands.claudeTyped(host, reach: nil, status: .idle, asking: false)
    #expect(row.abilities == [.settingsModel, .settingsEffort, .settingsMode, .compact] && row.reasons[SessionAbility.settingsFast.rawValue] == SessionCommands.fastRefusal)
    row = SessionCommands.claudeTyped(host, reach: nil, status: .idle, asking: true)
    #expect(row.abilities.isEmpty && row.reasons[SessionAbility.settingsMode.rawValue] == "Answer the open request first.")
    let plain = try #require(store.sessions.live.first { $0.pid == 922 })
    row = SessionCommands.claudeTyped(plain, reach: nil, status: .idle, asking: false)
    #expect(row.abilities.isEmpty && row.reasons[SessionAbility.settingsModel.rawValue] == "Changing settings needs a session Side A hosts."
            && row.reasons[SessionAbility.compact.rawValue] == "Compacting needs a session Side A hosts.")

    row = SessionCommands.claudeTyped(plain, reach: .tmux, status: .idle, asking: false)
    #expect(row.abilities == [.settingsModel, .settingsEffort, .settingsMode]
            && row.reasons[SessionAbility.compact.rawValue] == "Compacting needs a session Side A hosts.")
    row = SessionCommands.claudeTyped(plain, reach: .tmux, status: .working, asking: false)
    #expect(row.abilities.isEmpty && row.reasons[SessionAbility.settingsEffort.rawValue] == "Claude is working. Try when it's idle.")
    row = SessionCommands.claudeTyped(plain, reach: .ghostty, status: .idle, asking: false)
    #expect(row.abilities.isEmpty && row.reasons[SessionAbility.settingsModel.rawValue] == "Changing the model here needs the session to run in tmux or in Side A.")
    store.remote.typer.staged = [922: .ghostty]
    #expect(await failure("s-plain", SettingsChange(model: "sonnet"))?.message == "Changing the model here needs the session to run in tmux or in Side A.")
    store.remote.typer.staged = [922: .tmux]
    #expect(await failure("s-plain", SettingsChange(fast: true))?.message == SessionCommands.fastRefusal)
    #expect(await failure("s-plain", SettingsChange(model: "sonnet"))?.message == "The session isn't what its terminal shows right now.")
    store.remote.typer.staged = [:]
    refused = await compactFailure("s-plain")
    #expect(refused?.message == "Compacting needs a session Side A hosts.")
    refused = await compactFailure("s-host")
    #expect(refused?.message == "Claude is working. Try when it's idle.")
    store.sessions.compact(try #require(store.sessions.live.first { $0.pid == 922 }))
    for _ in 0..<50 where store.sessions.error == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(store.sessions.error == "Compacting needs a session Side A hosts.")
}

@MainActor @Test func theChangesSheetCountsEveryFileAndSaysWhileItRuns() {
    let files = [FileDiff(path: "a.swift", oldPath: nil, change: .modified, additions: 3, deletions: 1, hunks: [], truncated: false),
                 FileDiff(path: "b.swift", oldPath: nil, change: .added, additions: 2, deletions: 0, hunks: [], truncated: true)]
    #expect(ChangesSheet.summary(files, running: true) == "2 files · +5 −1 · still working")
    #expect(ChangesSheet.summary([files[0]], running: false) == "1 file · +3 −1")
    #expect(ChangesSheet.summary([], running: true) == nil)
}

@Test func aPhonesUploadsStopAtItsCap() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidea-uploads-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    func png(_ colour: CGFloat) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: colour, green: 0, blue: 0, alpha: 0.5)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }
    let first = try RemoteUploads.store(png(0.1), root: root, device: "d1")
    let cap = first.bytes + 1
    #expect(throws: RemoteUploads.Failure.full) { try RemoteUploads.store(try png(0.9), root: root, device: "d1", cap: cap) }
    #expect(try RemoteUploads.store(png(0.1), root: root, device: "d1", cap: cap).id == first.id)
    #expect(try RemoteUploads.store(png(0.9), root: root, device: "d2", cap: cap).bytes > 0)
    let mac = try RemoteUploads.store(png(0.5), root: root)
    #expect(RemoteUploads.paths([first.id], root: root, device: "d1")?.count == 1)
    #expect(RemoteUploads.paths([first.id], root: root, device: "d2") == nil && RemoteUploads.paths([mac.id], root: root, device: "d1") == nil)
    #expect(first.path.hasPrefix(RemoteUploads.folder(root, device: "d1").path))
    RemoteUploads.sweep(root: root, now: Date().addingTimeInterval(RemoteUploads.keepFor + 60))
    #expect(RemoteUploads.paths([first.id], root: root, device: "d1") == nil)
    #expect(try RemoteUploads.store(png(0.9), root: root, device: "d1", cap: cap).bytes > 0)
}

@Test func quittingGoesByAFreshList() {
    func session(_ pid: Int, _ status: String, started: Double = 1_700_000_000, hosted: String? = nil) -> LiveSession {
        var live = LiveSession(pid: pid, sessionID: "s\(pid)", name: nil, title: nil, cost: nil, cwd: "/tmp", status: status, waitingFor: nil, since: 0)
        live.started = started; live.hosted = hosted; live.kind = "interactive"
        return live
    }
    let shown = [session(1, "idle", hosted: "sa-app-1"), session(2, "idle"), session(3, "idle"), session(4, "idle", hosted: "sa-app-4")]
    let fresh = [session(1, "busy", hosted: "sa-app-1"), session(2, "idle"), session(3, "idle", started: 1_700_000_500), session(4, "idle", hosted: "sa-app-4")]
    #expect(SessionStore.current(shown, in: fresh) { $0.status == "idle" }.map(\.pid) == [2, 4])
    #expect(SessionStore.current(shown, in: [], still: { _ in true }).isEmpty)
}
