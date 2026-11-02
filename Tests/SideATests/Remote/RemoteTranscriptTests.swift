import Foundation
@testable import SideA
import SideACore
import Testing

/// The bridge's real answers, from a made-up transcript in a temporary home, through the wire mapping.
private final class Bridge {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sidea-transcript-\(UUID().uuidString)")
    var home: URL { folder.appendingPathComponent("home") }
    var root: URL { folder.appendingPathComponent("SideA") }
    let session = "11111111-2222-3333-4444-555555555555"

    init(_ lines: [[String: Any]]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try TranscriptFixture.write(lines, session: session, home: home)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// The reply line the app's SessionBridge gets: one request to `sessions serve`, on the system's python3 (as old as
    /// 3.9, whose argparse wants the id straight after the action).
    func reply(_ args: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", TranscriptFixture.bridge.path, "--root", root.path, "sessions", "serve"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: ["id": 1, "args": args]) + Data("\n".utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}

@Test func bridgePagesBecomeWireTranscriptsWithTheIslandsParse() throws {
    let image = TranscriptFixture.image
    let session = "11111111-2222-3333-4444-555555555555"
    let bridge = try Bridge(TranscriptFixture.lines(session: session, cwd: "/code/app"))

    let page = try RemoteTranscript.page(try bridge.reply(["show", session, "--format", "remote"]))
    #expect(page.sessionID == session && page.before == nil && page.count == page.messages.count && !page.reset)
    let first = try #require(page.messages.first)
    #expect(first.role == .user && first.text == "Fix the build" && first.at == 1_790_848_800)
    let ref = try #require(first.images.first)
    #expect(ref.id == RemoteImages.sha1(image) && ref.seq == first.seq && ref.source == .pasted && ref.width == 40)
    let tools = page.messages.flatMap(\.tools)
    #expect(tools.first { $0.id == "c1" }?.action == .command("npm test"))
    let edit = try #require(tools.first { $0.id == "c2" })
    #expect(edit.action == .edit(path: "/code/app/a.js", removed: "x = 1", added: "x = 2"))
    #expect(edit.diffs.first?.hunks.first?.oldStart == 1 && edit.diffs.first?.hunks.first?.lines == ["-x = 1", "+x = 2"] && edit.status == .ok)

    // The uncut row, and a stale generation, which the phone takes as a cue to page again.
    let row = try #require(page.messages.last)
    let whole = try RemoteTranscript.message(try bridge.reply(["message", session, "--seq", String(row.seq), "--generation", page.generation]))
    #expect(whole?.seq == row.seq && whole?.tools.map(\.id) == row.tools.map(\.id))
    #expect(try RemoteTranscript.message(try bridge.reply(["message", session, "--seq", "0", "--generation", "nope"])) == nil)
    #expect(throws: RemoteTranscript.Failure.self) { try RemoteTranscript.page(try bridge.reply(["show", "00000000-0000-0000-0000-000000000000", "--format", "remote"])) }

    // The image's bytes come from the transcript itself, checked against the id.
    let located = try SessionBridge.decode(try bridge.reply(["image", ref.id]), as: RemoteImages.Location.self)
    #expect(RemoteImages.read(located, id: ref.id) == image)
    #expect(RemoteImages.read(located, id: String(repeating: "0", count: 40)) == nil)
    let thumbs = bridge.root.appendingPathComponent("runtime/thumbs")
    #expect(RemoteImages.thumbnail(image, id: ref.id, folder: thumbs) != nil)
    #expect(FileManager.default.fileExists(atPath: thumbs.appendingPathComponent(ref.id + ".jpg").path))
}
