import SideAProtocol
import SideARemoteShared
import SwiftUI
import XCTest
@testable import SideARemote

@MainActor
final class SplitLayoutTests: XCTestCase {
    private let a = Route.session("a", mac: "m1")
    private let b = Route.session("b", mac: "m1")
    private let c = Route.session("c", mac: "m2")
    private let code = Route.code(CodePayload(id: "x", language: nil, code: "ls"))

    func testOnlyAFullWidthIPadSplits() {
        XCTAssertEqual(RootLayout.of(idiom: .pad, width: .regular), .split)
        XCTAssertEqual(RootLayout.of(idiom: .pad, width: .compact), .stack)
        XCTAssertEqual(RootLayout.of(idiom: .phone, width: .regular), .stack)
        XCTAssertEqual(RootLayout.of(idiom: .phone, width: .compact), .stack)
        XCTAssertEqual(RootLayout.of(idiom: .pad, width: nil), .stack)
    }

    func testTheFirstRouteIsTheDetailsRootAndTheRestIsPushedOverIt() {
        XCTAssertNil(SplitPath.root([]))
        XCTAssertEqual(SplitPath.pushed([]), [])
        XCTAssertEqual(SplitPath.root([a, code]), a)
        XCTAssertEqual(SplitPath.pushed([a, code]), [code])
        XCTAssertEqual(SplitPath.replacing(pushed: [], in: [a, code]), [a])
        XCTAssertEqual(SplitPath.replacing(pushed: [code], in: [a]), [a, code])
        XCTAssertEqual(SplitPath.replacing(pushed: [code], in: []), [])
    }

    func testPickingARowOpensItAloneAndPickingTheOpenOneKeepsItsPages() {
        XCTAssertEqual(SplitPath.selecting(b, in: [a, code]), [b])
        XCTAssertEqual(SplitPath.selecting(a, in: [a, code]), [a, code])
        XCTAssertEqual(SplitPath.selecting(nil, in: [a, code]), [])
    }

    func testDeepLinksLandInTheDetailColumn() throws {
        let link = try XCTUnwrap(DeepLink(URL(string: "sidea-remote://session/m1/a")!))
        let landing = link.landing(mac: "m1")
        XCTAssertEqual(landing.tab, .sessions)
        let path = try XCTUnwrap(landing.sessions)
        XCTAssertEqual(SplitPath.root(path), a)
        XCTAssertEqual(SplitPath.pushed(path), [])
        XCTAssertEqual(SplitPath.selection(path) { _, _ in nil }, a)
        let mac = try XCTUnwrap(DeepLink(URL(string: "sidea-remote://mac/m1")!))
        XCTAssertEqual(mac.landing(mac: "m1"), LinkLanding(tab: .sessions, sessions: []))
        XCTAssertNil(SplitPath.selection([]) { _, _ in nil })
        XCTAssertEqual(DeepLink(URL(string: "sidea-remote://settings")!)?.landing(mac: "m1"), LinkLanding(tab: .sessions, sheet: .settings))
        XCTAssertEqual(DeepLink(URL(string: "sidea-remote://accounts/x")!)?.landing(mac: "m1").accounts, [.account("x", mac: "m1")])
    }

    func testAStartingSessionsRowTurnsIntoItsSessionOnceListed() {
        let starting = [Route.starting("sa-side-a-1", mac: "m1")]
        XCTAssertEqual(SplitPath.selection(starting) { _, _ in nil }, starting[0])
        XCTAssertEqual(SplitPath.selection(starting) { name, mac in name == "sa-side-a-1" && mac == "m1" ? "a" : nil }, a)
    }

    func testNextAndPreviousSessionStopAtTheEnds() {
        let order = [a, b, c]
        XCTAssertEqual(SplitPath.neighbor(of: a, in: order, step: 1), b)
        XCTAssertEqual(SplitPath.neighbor(of: b, in: order, step: -1), a)
        XCTAssertNil(SplitPath.neighbor(of: c, in: order, step: 1))
        XCTAssertNil(SplitPath.neighbor(of: a, in: order, step: -1))
        XCTAssertEqual(SplitPath.neighbor(of: nil, in: order, step: 1), a)
        XCTAssertEqual(SplitPath.neighbor(of: Route.session("idle", mac: "m1"), in: order, step: -1), c)
        XCTAssertNil(SplitPath.neighbor(of: nil, in: [], step: 1))
    }

    func testTheSidebarOrderLeadsWithWhatNeedsYou() throws {
        let root = AppRoot(arguments: ["--demo"])
        let model = root.model
        let order = root.sidebarOrder
        let needsYou = model.sessions.rows(.needsYou).filter { !model.tools.isPinned($0) }
        XCTAssertFalse(needsYou.isEmpty)
        XCTAssertEqual(Array(order.prefix(needsYou.count)), needsYou.map { Route.session($0.id, mac: model.macID) })
        XCTAssertFalse(order.contains { route in model.sessions.rows(.idle).contains { Route.session($0.id, mac: model.macID) == route } })
        XCTAssertEqual(Set(order).count, order.count)
    }

    func testATabsMarginsCentreCardsAtTheReadingWidth() {
        XCTAssertEqual(1366 - 2 * Readable.margin(in: 1366), Readable.width)
        XCTAssertEqual(1032 - 2 * Readable.margin(in: 1032), Readable.width)
        XCTAssertEqual(Readable.margin(in: 700), Space.l)
    }

    func testTheWaitingCapsuleHidesOnlyBesideItsOwnSession() {
        XCTAssertTrue(SplitPath.showsWaiting(for: "a", path: []))
        XCTAssertTrue(SplitPath.showsWaiting(for: "a", path: [b]))
        XCTAssertFalse(SplitPath.showsWaiting(for: "a", path: [a]))
        XCTAssertFalse(SplitPath.showsWaiting(for: "a", path: [a, code]))
        XCTAssertTrue(SplitPath.showsWaiting(for: nil, path: [a]))
    }

    func testTheDeviceIsNamedByItsModel() {
        XCTAssertEqual(ThisDevice.kind(model: "iPad16,3"), "iPad")
        XCTAssertEqual(ThisDevice.kind(model: "iPhone17,1"), "iPhone")
        XCTAssertEqual(ThisDevice.kind(model: "arm64"), "iPhone")
    }

    func testTheApprovalPayloadIsAShareOfTheWindow() {
        func request(_ action: IslandAction) -> RemoteRequest {
            RemoteRequest(id: "r", sessionID: "s", agent: .claude, tool: "Bash", action: action, headline: "Allow Bash", risk: .normal,
                          answers: [.allow, .deny], title: "t", arrivedAt: 0)
        }
        XCTAssertEqual(ApprovalSheet.payloadLimit(request(.command("ls")), window: 900), 300)
        XCTAssertEqual(ApprovalSheet.payloadLimit(request(.write(path: "a", content: "b")), window: 900), 405)
    }

    func testNewSessionsDraftOutlivesItsSheet() {
        let root = AppRoot(arguments: ["--demo"])
        let form = root.newSession
        form.prompt = "Keep me"
        form.worktree = true
        XCTAssertTrue(root.newSession === form)
        XCTAssertEqual(root.newSession.prompt, "Keep me")
        let fresh = NewSessionForm()
        XCTAssertNotEqual(fresh.draft, form.draft)
        XCTAssertNotEqual(fresh.key, form.key)
        XCTAssertEqual(fresh.prompt, "")
    }

    func testADropTakesOnlyWhatFits() {
        XCTAssertEqual(PhotoDrop.taken(3, room: 10), 3)
        XCTAssertEqual(PhotoDrop.taken(12, room: 10), 10)
        XCTAssertEqual(PhotoDrop.taken(2, room: 0), 0)
    }

    func testADroppedImageArrivesAtTheUploadsSize() throws {
        let size = CGSize(width: 6000, height: 3000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let big = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "drop-\(UUID().uuidString).png")
        try XCTUnwrap(big.pngData()).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let prepared = try XCTUnwrap(ComposerAttachments.prepare(file: file))
        let longest = max(prepared.preview.size.width, prepared.preview.size.height) * prepared.preview.scale
        XCTAssertEqual(longest, CGFloat(ComposerAttachments.longEdge))
    }
}
