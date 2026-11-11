import Foundation
@testable import SideA
import SideACore
import Testing

/// One hung step used to stop every reading, the usage report and Autopilot until Side A was restarted.
@MainActor @Test func theLoopGoesOnWithoutAStepThatNeverComesBack() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))")
    let store = AccountStore(demo: true, root: root)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("runtime"), withIntermediateDirectories: true)
    let studio = store.config.accounts[1]
    var reads = 0
    store.testBridge = { _ in
        reads += 1
        // The first read never answers, and ignores being cancelled, as a wedged helper would.
        if reads == 1 { await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in } }
        throw BridgeFailure(stderr: "Side A[signin]: Sign in to Studio again.")
    }
    #expect(await store.watched(limit: .milliseconds(50)) { await $0.refreshUsage(studio.id) } == false)
    let log = try String(contentsOf: root.appendingPathComponent("runtime/autopilot.log"), encoding: .utf8)
    #expect(log.contains("A background check stopped at its start and didn't come back"))

    // The read it was in the middle of doesn't hold the next one back.
    #expect(await store.watched(limit: .seconds(5)) { await $0.refreshUsage(studio.id) })
    #expect(reads == 2 && store.health[studio.id] == .signIn())
}

@MainActor @Test func aStepThatFinishesIsNotLeftBehind() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))")
    let store = AccountStore(demo: true, root: root)
    var ran = false
    #expect(await store.watched(limit: .seconds(5)) { _ in ran = true })
    #expect(ran && !FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime/autopilot.log").path))
}
