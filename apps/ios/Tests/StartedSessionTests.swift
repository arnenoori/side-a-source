import SideAProtocol
import XCTest
@testable import SideARemote

@MainActor
final class StartedSessionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func row(_ id: String, _ status: SessionStatus, hosted: String? = "sa-side-a-1a2b") -> RemoteSession {
        RemoteSession(id: id, agent: .claude, title: "Fix the tests", project: "side-a", status: status, statusAt: 1_000, hosted: hosted)
    }

    private func store() -> SessionsStore {
        SessionsStore([], macID: "m", defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard)
    }

    private func phase(_ store: SessionsStore, _ id: String) -> SessionPhase? {
        SessionPhase.allCases.first { store.rows($0).contains { $0.id == id } }
    }

    func testAStartedSessionTheMacCallsIdleIsWorkingNotIdle() {
        let store = store()
        store.launch("sa-side-a-1a2b", at: t0)
        store.replace([row("c1", .idle)], finished: [:], now: t0.addingTimeInterval(4))
        XCTAssertEqual(phase(store, "c1"), .working)
        XCTAssertEqual(store.session("c1")?.status, .starting)
        XCTAssertTrue(store.rows(.idle).isEmpty)
    }

    func testItNeverVisitsIdleOnTheWayToItsFirstTurn() {
        let store = store()
        store.launch("sa-side-a-1a2b", at: t0)
        var seen: [SessionPhase?] = []
        for (second, status) in [(2.0, SessionStatus.idle), (5, .idle), (8, .working), (40, .finished)] {
            store.replace([row("c1", status)], finished: [:], now: t0.addingTimeInterval(second))
            seen.append(phase(store, "c1"))
        }
        XCTAssertEqual(seen, [.working, .working, .working, .ready])
    }

    func testTheFirstTurnHandsTheRowBackToTheMacsWord() {
        let store = store()
        store.launch("sa-side-a-1a2b", at: t0)
        store.replace([row("c1", .working)], finished: [:], now: t0.addingTimeInterval(5))
        XCTAssertNil(store.launching["sa-side-a-1a2b"])
        store.replace([row("c1", .idle)], finished: [:], now: t0.addingTimeInterval(30))
        XCTAssertEqual(phase(store, "c1"), .idle)
    }

    func testALaunchThatNeverTakesItsPromptSettlesIntoIdle() {
        let store = store()
        store.launch("sa-side-a-1a2b", at: t0)
        store.replace([row("c1", .idle)], finished: [:], now: t0.addingTimeInterval(SessionsStore.launchGrace + 1))
        XCTAssertEqual(phase(store, "c1"), .idle)
    }

    func testAnEndedLaunchIsLetGo() {
        let store = store()
        store.launch("sa-side-a-1a2b", at: t0)
        store.endLaunch("sa-side-a-1a2b")
        store.replace([row("c1", .idle)], finished: [:], now: t0.addingTimeInterval(3))
        XCTAssertEqual(phase(store, "c1"), .idle)
    }

    func testSessionsTheMacStartedOrNotLaunchedKeepTheirStatus() {
        let store = store()
        store.launch("sa-other", at: t0)
        store.replace([row("c1", .idle), row("c2", .idle, hosted: nil)], finished: [:], now: t0.addingTimeInterval(3))
        XCTAssertEqual(phase(store, "c1"), .idle)
        XCTAssertEqual(phase(store, "c2"), .idle)
    }

    func testAnUnchangedPollDoesNotRebucketALaunchingRow() {
        let store = store()
        store.launch("sa-side-a-1a2b", at: t0)
        store.replace([row("c1", .idle)], finished: [:], now: t0.addingTimeInterval(3))
        let before = store.rows(.working)
        store.replace([row("c1", .idle)], finished: [:], now: t0.addingTimeInterval(6))
        XCTAssertEqual(store.rows(.working), before)
    }

    func testThePlaceholderAndTheRealRowAreOneListIdentity() {
        let hosted = HostedSession(name: "sa-side-a-1a2b", agent: .claude, cwd: "/p", project: "side-a", createdAt: 1_000)
        let placeholder = SessionsStore.placeholder(hosted, prompt: "Fix the tests")
        XCTAssertEqual(placeholder.status, .starting)
        XCTAssertEqual(SessionPhase(placeholder), .working)
        XCTAssertEqual(placeholder.rowID, row("a1b2c3", .working).rowID)
    }

    func testABootingRowLeadsItsPhaseAndSearchStillFindsIt() {
        let store = store()
        store.replace([RemoteSession(id: "old", agent: .claude, title: "Other", project: "side-a", status: .working, statusAt: 1_000)], finished: [:], now: t0)
        let hosted = HostedSession(name: "sa-side-a-1a2b", agent: .claude, cwd: "/p", project: "side-a", createdAt: 2_000)
        let booting = SessionsStore.placeholder(hosted, prompt: "Fix the tests")
        let rows = store.groups(.working, leading: [booting]) { store.matches($0, "tests") }.flatMap(\.rows)
        XCTAssertEqual(rows.map(\.id), ["tmux-sa-side-a-1a2b"])
        let all = store.groups(.working, leading: [booting]).flatMap(\.rows)
        XCTAssertEqual(all.map(\.id), ["tmux-sa-side-a-1a2b", "old"])
    }
}
