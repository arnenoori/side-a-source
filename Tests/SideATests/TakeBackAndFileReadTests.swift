import Foundation
@testable import SideA
import SideAProtocol
import Testing

private let long = "first line\nsecond line\nthird line"

@Test func aStopTakesBackOnlyARunOfThePhonesNewestReplies() throws {
    let both = try #require(HostedSessions.taken(["one", "two"], shown: "one\ntwo"))
    #expect(both == (0, false))
    let last = try #require(HostedSessions.taken(["one", "two"], shown: " two "))
    #expect(last == (1, false))
    #expect(HostedSessions.taken(["one", "two"], shown: "one") == nil)
    #expect(HostedSessions.taken(["one", "two"], shown: "two\nand something typed at the Mac") == nil)
    let pastedAfter = try #require(HostedSessions.taken(["a", long], shown: "a\n[Pasted text #2 +3 lines]"))
    #expect(pastedAfter == (0, true))
    let pastedAlone = try #require(HostedSessions.taken(["a", long], shown: "[Pasted text #2 +3 lines]"))
    #expect(pastedAlone == (1, true))
    #expect(HostedSessions.taken(["hi"], shown: "[Pasted text #2 +3 lines]") == nil)
    #expect(HostedSessions.taken([long, long], shown: "[Pasted text #2 +3 lines][Pasted text #3 +3 lines]") == nil)
    #expect(HostedSessions.taken([], shown: "x") == nil)
}

@Test func secretNamesAreKnownByAnyPartOfThePath() {
    for parts in [["config", ".ssh", "x"], [".git", "config"], [".env"], [".env.local"], ["id_rsa"], ["id_ed25519.pub"], ["server.KEY"],
                  ["prod.tfstate.backup"], ["Secrets.json"], ["credentials.json"], ["auth.json"], ["a", "b", "app.mobileprovision"]] {
        #expect(FileReads.secret(parts), "\(parts)")
    }
    for parts in [["src", "main.swift"], ["keys.swift"], ["environment.md"], ["docs", "secret-handling.md"]] {
        #expect(!FileReads.secret(parts), "\(parts)")
    }
}

@Suite struct FileReadRefusals {
    let root: URL
    let outside: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("file-reads-\(UUID().uuidString)")
        root = base.appendingPathComponent("project")
        outside = base.appendingPathComponent("elsewhere")
        for folder in [root, outside, root.appendingPathComponent(".git"), root.appendingPathComponent("sub")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for name in ["a.txt", ".env", "id_rsa", ".git/config", "b.txt"] { try Data("x".utf8).write(to: root.appendingPathComponent(name)) }
        try Data("x".utf8).write(to: outside.appendingPathComponent("key.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("out.txt"), withDestinationURL: outside.appendingPathComponent("key.txt"))
        try FileManager.default.linkItem(at: root.appendingPathComponent("b.txt"), to: root.appendingPathComponent("c.txt"))
    }

    private func read(_ path: String) async -> String {
        switch await FileReads.read(path, in: root.path) {
        case .success(let data): String(decoding: data, as: UTF8.self)
        case .failure(.missing): "missing"
        case .failure(.folder): "folder"
        case .failure(.tooLarge): "tooLarge"
        case .failure(.refused(let reason)): reason.rawValue
        }
    }

    @Test func eachRuleRefusesWithItsOwnReason() async throws {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        #expect(await read("a.txt") == "x")
        #expect(await read(root.appendingPathComponent("a.txt").path) == "x")
        #expect(await read("out.txt") == "outside")
        #expect(await read(outside.appendingPathComponent("key.txt").path) == "outside")
        #expect(await read("../elsewhere/key.txt") == "outside")
        #expect(await read(".env") == "secret")
        #expect(await read("id_rsa") == "secret")
        #expect(await read(".git/config") == "secret")
        #expect(await read("c.txt") == "linked")
        #expect(await read("nothing.txt") == "missing")
        #expect(await read("sub") == "folder")
        let big = root.appendingPathComponent("big.bin")
        try Data(count: FileReads.most + 1).write(to: big)
        #expect(await read("big.bin") == "tooLarge")
        try Data(count: FileReads.most).write(to: big)
        #expect(await read("big.bin").count == FileReads.most)
    }
}
