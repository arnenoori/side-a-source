import Foundation
@testable import SideA
import Testing

private actor Counter {
    var runs = 0
    func next() -> Int { runs += 1; return runs }
}

/// Requests that arrive together share one run; a kept value lasts its ttl or until the generation moves on.
@Test func remoteCacheSharesRunsAndExpires() async throws {
    let cache = RemoteCache(), counter = Counter()
    let make: @Sendable () async throws -> Int = {
        try await Task.sleep(for: .milliseconds(50))
        return await counter.next()
    }
    async let a = cache.value("k", ttl: 60, make)
    async let b = cache.value("k", ttl: 60, make)
    #expect(try await [a, b] == [1, 1])
    #expect(try await cache.value("k", ttl: 60, make) == 1)
    #expect(try await cache.value("k", ttl: 60, generation: 1, make) == 2)
    #expect(try await cache.value("k", ttl: 0, generation: 1, make) == 3)
    #expect(try await cache.value("other", ttl: 60, make) == 4)
    await cache.clear()
    #expect(try await cache.value("k", ttl: 60, generation: 1, make) == 5)
}

/// A run that fails is never served again.
@Test func remoteCacheDropsFailures() async throws {
    struct Failure: Error {}
    let cache = RemoteCache(), counter = Counter()
    await #expect(throws: Failure.self) { try await cache.value("k", ttl: 60) { () async throws -> Int in _ = await counter.next(); throw Failure() } }
    #expect(try await cache.value("k", ttl: 60) { await counter.next() } == 2)
}

/// Git for many folders runs a few at a time and keeps each folder's answer.
@Test func projectGitRunsTogetherAndIsKept() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("sa-gits-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: base) }
    var paths: [String] = []
    for n in 0..<10 {
        let folder = base.appendingPathComponent("p\(n)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if n % 2 == 0 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder.path, "init", "-q", "-b", "b\(n)"]
            try process.run(); process.waitUntilExit()
        }
        paths.append(folder.path)
    }
    let cache = RemoteCache()
    let first = await RemoteProjects.gits(paths, cache: cache)
    #expect(first.map(\.branch) == paths.indices.map { $0 % 2 == 0 ? "b\($0)" : nil })
    #expect(first.enumerated().allSatisfy { n, git in (git.root != nil) == (n % 2 == 0) })
    // Kept: a branch made now shows only once the half minute is up.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", paths[0], "checkout", "-q", "-b", "later"]
    try process.run(); process.waitUntilExit()
    #expect(await RemoteProjects.gits([paths[0]], cache: cache).first?.branch == "b0")
    #expect(await RemoteProjects.gits([paths[0]], cache: RemoteCache()).first?.branch == "later")
}
