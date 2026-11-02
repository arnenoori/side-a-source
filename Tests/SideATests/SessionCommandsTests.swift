import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

/// The Sessions window calls the same commands the phone's routes do, without HTTP: values back, or the phone's words.
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

/// A photo pasted into the composer is stored as the phone's uploads are, and its path goes with the reply.
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

/// The composer's list: the word at the caret, "$" only for Codex, prefix matches first, and a space after the choice.
@Test func suggestionsFollowTheWordAtTheCaret() {
    let options = [("/review", "Review"), ("/clear", "Clear"), ("/prompts:release", "Release"), ("$ship", "Ship"), ("$imagegen", "Images")]
        .map { ComposerSuggestions.Option(id: $0.0, label: $0.1) }
    #expect(ComposerSuggestions.word(in: "please /re", caret: 10, codex: false)?.word == "/re")
    #expect(ComposerSuggestions.word(in: "please /re", caret: 6, codex: false) == nil)
    #expect(ComposerSuggestions.word(in: "$sh", caret: 3, codex: false) == nil)
    #expect(ComposerSuggestions.word(in: "$sh", caret: 3, codex: true)?.word == "$sh")
    #expect(ComposerSuggestions.matches("/re", in: options).map(\.id) == ["/review", "/prompts:release"])
    #expect(ComposerSuggestions.matches("$", in: options).map(\.id) == ["$ship", "$imagegen"])
    let found = ComposerSuggestions.word(in: "/re then", caret: 3, codex: false)!
    #expect(ComposerSuggestions.apply(options[0], to: "/re then", at: found.range) == "/review then")
    #expect(ComposerSuggestions.apply(options[0], to: "/re", at: NSRange(location: 0, length: 3)) == "/review ")
}

/// Allow and switch mode through the island: an edit takes it from the phone with its gate's proof; a destructive
/// request refuses it even with Face ID, as it isn't offered; a plan never takes one from the Mac either.
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

/// The chip reads the phone's row: what the session runs with, defaults left out, and changes only where it takes them.
@MainActor @Test func theSettingsChipReadsThePhonesRow() throws {
    let store = try store([["pid": 951, "id": "s-set", "status": "busy", "agent": "claude"]])
    store.sessions.live[0].model = "claude-opus-5-5"
    store.sessions.live[0].effort = "high"
    store.sessions.live[0].mode = "default"
    store.sessions.live[0].contextPercent = 41.6
    let row = WireBuilders.session(store.sessions.live[0], store: store, finished: [])
    #expect(SettingsChip.summary(row) == "\(ModelName.short("claude-opus-5-5")) · High · 42% context")
    // Efforts go by the phone's names.
    store.sessions.live[0].effort = "xhigh"
    #expect(SettingsChip.summary(WireBuilders.session(store.sessions.live[0], store: store, finished: [])) == "\(ModelName.short("claude-opus-5-5")) · Extra high · 42% context")
    // Background tasks, as the phone counts them; none says nothing.
    store.sessions.live[0].backgroundTasks = (1...2).map { n in LiveSession.BackgroundTask(id: "t\(n)", type: "bash", status: "running", description: nil) }
    #expect(SettingsChip.summary(WireBuilders.session(store.sessions.live[0], store: store, finished: []))?.hasSuffix("42% context · 2 running") == true)
    store.sessions.live[0].backgroundTasks = [LiveSession.BackgroundTask(id: "t3", type: "bash", status: "completed", description: nil)]
    #expect(SettingsChip.summary(WireBuilders.session(store.sessions.live[0], store: store, finished: []))?.hasSuffix("42% context") == true)
    #expect([Effort.auto, .low, .xhigh, .max, Effort(rawValue: "turbo")].map(\.title) == ["Auto", "Low", "Extra high", "Max", "Turbo"])
    // A Claude session outside a pane has nothing the Mac can change; Side A says so rather than offering it.
    #expect(!SettingsChip.changeable(row))
    store.sessions.live[0].model = nil; store.sessions.live[0].effort = nil; store.sessions.live[0].mode = nil; store.sessions.live[0].contextPercent = nil
    #expect(SettingsChip.summary(WireBuilders.session(store.sessions.live[0], store: store, finished: [])) == nil)
}

/// Settings go to each agent's driver: hosted Claude while it's idle, Codex on its app server; anything else says why.
@MainActor @Test func settingsGoOnlyWhereADriverCanTakeThem() async throws {
    let store = try store([["pid": 921, "id": "s-host", "status": "busy", "agent": "claude", "hosted": "sa-app-1"],
                           ["pid": 922, "id": "s-plain", "status": "idle", "agent": "claude"],
                           ["pid": 923, "id": "c-plain", "status": "idle", "agent": "codex"]])
    let commands = SessionCommands(store: store)
    func failure(_ id: String, _ change: SettingsChange) async -> SessionCommands.Failure? {
        do { _ = try await commands.settings(id, change); return nil } catch { return error }
    }
    func compactFailure(_ id: String) async -> SessionCommands.Failure? {
        do { try await commands.compact(id); return nil } catch { return error }
    }
    var refused = await failure("s-plain", SettingsChange(model: "sonnet"))
    #expect(refused?.status == 409 && refused?.code == "cannot_deliver" && refused?.message == "Changing settings needs a session Side A hosts.")
    refused = await failure("c-plain", SettingsChange(mode: .plan))
    #expect(refused?.code == "cannot_deliver")
    refused = await failure("s-host", SettingsChange(fast: true))
    #expect(refused?.status == 422 && refused?.message == SessionCommands.fastRefusal)
    refused = await failure("s-host", SettingsChange(effort: .auto))
    #expect(refused?.status == 422)
    refused = await failure("s-host", SettingsChange(model: "sonnet"))
    #expect(refused?.status == 409 && refused?.message == "Claude is working. Try when it's idle.")
    #expect(await failure("gone", SettingsChange(model: "sonnet")) == .noSession)

    // The row says the same.
    let host = try #require(store.sessions.live.first { $0.pid == 921 })
    var row = SessionCommands.claudeTyped(host, status: .idle, asking: false)
    #expect(row.abilities == [.settingsModel, .settingsEffort, .settingsMode, .compact] && row.reasons[SessionAbility.settingsFast.rawValue] == SessionCommands.fastRefusal)
    row = SessionCommands.claudeTyped(host, status: .idle, asking: true)
    #expect(row.abilities.isEmpty && row.reasons[SessionAbility.settingsMode.rawValue] == "Answer the open request first.")
    row = SessionCommands.claudeTyped(try #require(store.sessions.live.first { $0.pid == 922 }), status: .idle, asking: false)
    #expect(row.abilities.isEmpty && row.reasons[SessionAbility.settingsModel.rawValue] == "Changing settings needs a session Side A hosts."
            && row.reasons[SessionAbility.compact.rawValue] == "Compacting needs a session Side A hosts.")
    // Compact: hosted and idle only.
    refused = await compactFailure("s-plain")
    #expect(refused?.message == "Compacting needs a session Side A hosts.")
    refused = await compactFailure("s-host")
    #expect(refused?.message == "Claude is working. Try when it's idle.")
    // Asking Compact from the window anyway says why there.
    store.sessions.compact(try #require(store.sessions.live.first { $0.pid == 922 }))
    for _ in 0..<50 where store.sessions.error == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(store.sessions.error == "Compacting needs a session Side A hosts.")
}

@MainActor @Test func theChangesSheetCountsEveryFileAndSaysWhileItRuns() {
    let files = [FileDiff(path: "a.swift", oldPath: nil, change: .modified, additions: 3, deletions: 1, hunks: [], truncated: false),
                 FileDiff(path: "b.swift", oldPath: nil, change: .added, additions: 2, deletions: 0, hunks: [], truncated: true)]
    #expect(TurnDiffSheet.summary(TurnDiff(sessionID: "s", turnID: "t", files: files, running: true, note: nil)) == "2 files · +5 −1 · still working")
    #expect(TurnDiffSheet.summary(TurnDiff(sessionID: "s", turnID: "t", files: [files[0]], running: false, note: nil)) == "1 file · +3 −1")
    #expect(TurnDiffSheet.summary(TurnDiff(sessionID: "s", turnID: "t", files: [], running: true, note: nil)) == nil)
}

/// A stolen token can send photos without a signature, so each phone has a total and hears when it's reached.
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
    // The same photo again takes no more room; another phone, and the Mac, have their own room.
    #expect(try RemoteUploads.store(png(0.1), root: root, device: "d1", cap: cap).id == first.id)
    #expect(try RemoteUploads.store(png(0.9), root: root, device: "d2", cap: cap).bytes > 0)
    let mac = try RemoteUploads.store(png(0.5), root: root)
    #expect(RemoteUploads.paths([first.id, mac.id], root: root)?.count == 2)
    #expect(first.path.hasPrefix(RemoteUploads.folder(root, device: "d1").path))
    // A week on, a phone's photos go and its room comes back.
    RemoteUploads.sweep(root: root, now: Date().addingTimeInterval(RemoteUploads.keepFor + 60))
    #expect(RemoteUploads.paths([first.id], root: root) == nil)
    #expect(try RemoteUploads.store(png(0.9), root: root, device: "d1", cap: cap).bytes > 0)
}
