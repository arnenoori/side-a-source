import AppKit
import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import SideARemoteKit
import SwiftUI
import Testing

/// Pictures of the Mac's move views in the states two real hosts produce, light and dark, for a look before a release:
/// `SIDEA_MOVE_SHOTS=~/scratch/move-shots swift test --filter moveShots`. Skipped otherwise.
private let shots = ProcessInfo.processInfo.environment["SIDEA_MOVE_SHOTS"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
private let hasTmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }

/// Hosted in an offscreen window so AppKit-backed controls draw as they do in the app. `settle` is how long the view's own
/// loading (a preview asks both computers) is given before the picture.
@MainActor private func shoot(_ view: some View, _ name: String, size: CGSize, settle: Duration = .milliseconds(900)) async throws {
    guard let shots else { return }
    _ = NSApplication.shared
    try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
    for dark in [false, true] {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        // swiftlint:disable:next sleep_as_sync_in_tests -- a screenshot, not an assertion: AppKit gives no signal that the window has drawn
        try await Task.sleep(for: settle)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: shots.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        window.orderOut(nil)
    }
}

@MainActor @Test(.enabled(if: shots != nil && hasTmux), .timeLimit(.minutes(10))) func moveShots() async throws {
    let (laptop, mini, peer) = try await pair()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))")
    let store = AccountStore(demo: true, root: folder)
    store.remote.moves = laptop.moves
    laptop.moves.peer = { _ in peer }
    let (here, _) = accounts(laptop, mini)
    let computer = LinkedComputer(id: "Mac mini", name: "Mac mini", endpoint: Endpoint(macID: "Mac mini", baseURL: try #require(URL(string: "https://127.0.0.1:1")), serverKeyHash: "", name: "Mac mini"),
                                  token: "", linked: 0)
    let sheet = CGSize(width: 440, height: 300), list = CGSize(width: 320, height: 150)
    do {
        let session = try await laptop.startSession()
        let proposal = Moves.Proposal(session: session, computer: computer)
        try await shoot(MoveSheet(store: store, proposal: proposal), "sheet-1-login-goes", size: sheet, settle: .seconds(6))

        here.staying = "Work is the account new sessions here use"
        try await shoot(MoveSheet(store: store, proposal: proposal), "sheet-2-login-stays", size: sheet, settle: .seconds(6))
        here.staying = nil

        mini.moves.accepts = { false }
        try await shoot(MoveSheet(store: store, proposal: proposal), "sheet-3-refused", size: sheet, settle: .seconds(6))
        mini.moves.accepts = { true }

        laptop.status = { "busy" }
        let working = try #require(laptop.live().first)
        try await shoot(MoveSheet(store: store, proposal: Moves.Proposal(session: working, computer: computer)), "sheet-4-working", size: CGSize(width: 440, height: 360), settle: .seconds(6))
        laptop.status = { "idle" }

        peer.lose = .commitAnswer
        _ = try? await laptop.moves.send(session, to: peer)
        peer.lose = nil
        try await shoot(AwaySessions(store: store).font(.system(size: 12.5)), "list-1-unknown", size: list)
        await laptop.moves.settle()
        try await shoot(AwaySessions(store: store).font(.system(size: 12.5)), "list-2-away", size: list)
    } catch { Issue.record(error) }
    try? FileManager.default.removeItem(at: folder)
    await laptop.cleanUp()
    await mini.cleanUp()
}
