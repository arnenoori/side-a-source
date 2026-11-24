import SideAProtocol
import SideARemoteShared
import XCTest
@testable import SideARemote

@MainActor
final class FewerStepsTests: XCTestCase {
    private func request(_ action: IslandAction = .command("swift test"), id: RequestID = "r", gate: AllowGate? = nil,
                         truncated: Bool = false) -> RemoteRequest {
        RemoteRequest(id: id, sessionID: "s", agent: .claude, tool: "Bash", action: action, risk: .normal,
                      answers: [.allow, .deny], title: "t", arrivedAt: 0, truncated: truncated, gate: gate)
    }

    private func session(_ status: SessionStatus, background: Int? = nil, ports: [ListeningPort]? = nil) -> RemoteSession {
        var session = RemoteSession(id: "s", agent: .claude, title: "s", project: "side-a", status: status, statusAt: 1_000)
        session.backgroundTasks = background
        session.ports = ports
        return session
    }

    func testARowSwipeAllowsOnlyWhatItShowsWholeAndNeedsNoFaceID() {
        XCTAssertTrue(request().allowsFromRow)
        XCTAssertFalse(request(gate: .biometric).allowsFromRow)
        XCTAssertFalse(request(.command(String(repeating: "x", count: 40))).allowsFromRow)
        XCTAssertFalse(request(truncated: true).allowsFromRow)
        XCTAssertFalse(request(.edit(path: "/a.swift", removed: "x", added: "y")).allowsFromRow)
    }

    func testTheCardAllowsInPlaceOnlyWhenItShowsAllOfIt() {
        XCTAssertTrue(request(gate: .biometric).allowsOnCard(whole: true))
        XCTAssertFalse(request(gate: .biometric).allowsOnCard(whole: false))
        XCTAssertFalse(request(gate: .biometric, truncated: true).allowsOnCard(whole: true))
        XCTAssertFalse(request(.plan("# Plan")).allowsOnCard(whole: true))
    }

    func testQuitAsksOnlyWhenSomethingWouldBeLost() {
        XCTAssertFalse(SessionActions.quitAsks(session(.idle)))
        XCTAssertFalse(SessionActions.quitAsks(session(.finished)))
        XCTAssertFalse(SessionActions.quitAsks(session(.idle, background: 0)))
        XCTAssertTrue(SessionActions.quitAsks(session(.working)))
        XCTAssertTrue(SessionActions.quitAsks(session(.waiting)))
        XCTAssertTrue(SessionActions.quitAsks(session(.idle, background: 2)))
        XCTAssertTrue(SessionActions.quitAsks(session(.idle, ports: [ListeningPort(port: 3000, process: "node")])))
        var asking = session(.idle)
        asking.openRequests = ["r"]
        XCTAssertTrue(SessionActions.quitAsks(asking))
    }

    func testStoppingAServerAsksOnlyOfASessionAtWork() {
        let ports = [ListeningPort(port: 3000, process: "node")]
        XCTAssertFalse(SessionActions.stopAsks(session(.idle, ports: ports)))
        XCTAssertTrue(SessionActions.stopAsks(session(.working, ports: ports)))
        XCTAssertTrue(SessionActions.stopAsks(session(.finished, background: 1, ports: ports)))
    }

    func testGroupingIsKeptAcrossLaunches() throws {
        let suite = "FewerStepsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SessionsStore([], defaults: defaults).groupBy, .project)
        SessionsStore([], defaults: defaults).groupBy = .account
        XCTAssertEqual(SessionsStore([], defaults: defaults).groupBy, .account)
        SessionsStore([], defaults: defaults).groupBy = .none
        XCTAssertEqual(SessionsStore([], defaults: defaults).groupBy, .none)
    }

    func testPagingStopsAtEitherEnd() {
        let open = [request(id: "a"), request(id: "b"), request(id: "c")]
        XCTAssertEqual(ApprovalSheet.neighbor(of: "a", by: 1, in: open), "b")
        XCTAssertEqual(ApprovalSheet.neighbor(of: "b", by: -1, in: open), "a")
        XCTAssertNil(ApprovalSheet.neighbor(of: "a", by: -1, in: open))
        XCTAssertNil(ApprovalSheet.neighbor(of: "c", by: 1, in: open))
        XCTAssertNil(ApprovalSheet.neighbor(of: "gone", by: 1, in: open))
    }

    func testOnlyALongSidewaysDragTurnsAPage() {
        XCTAssertEqual(ApprovalSheet.pageOffset(for: CGSize(width: -120, height: 10)), 1)
        XCTAssertEqual(ApprovalSheet.pageOffset(for: CGSize(width: 120, height: -10)), -1)
        XCTAssertNil(ApprovalSheet.pageOffset(for: CGSize(width: 40, height: 0)))
        XCTAssertNil(ApprovalSheet.pageOffset(for: CGSize(width: 90, height: 80)))
    }

    func testAWorkingPillStaysUntilItsWorkEnds() {
        let pill = Pill()
        let id = pill.working("Compacting")
        XCTAssertEqual(pill.current?.text, "Compacting")
        XCTAssertTrue(pill.current?.working == true)
        pill.show("Compacted")
        pill.end(id)
        XCTAssertEqual(pill.current?.text, "Compacted")
        let next = pill.working("Forking")
        pill.end(next)
        XCTAssertNil(pill.current)
    }
}
