import SideAProtocol
import XCTest
@testable import SideARemote

@MainActor
final class HistoryTests: XCTestCase {
    private func past(_ id: String, _ project: String = "side-a", parent: String? = nil, at: Double = 0) -> PastSession {
        PastSession(id: id, agent: .claude, title: id, project: project, cwd: "/p/\(project)", lastAt: at, parentID: parent)
    }

    func testForksSitUnderTheirParentsInTheParentsProject() {
        let groups = HistoryTree.byProject([past("a", at: 9), past("b", "notes", at: 8), past("a1", parent: "a", at: 7),
                                            past("a1x", "notes", parent: "a1", at: 6), past("c", at: 5)])
        XCTAssertEqual(groups.map(\.project), ["side-a", "notes"])
        XCTAssertEqual(groups[0].rows.map(\.session.id), ["a", "a1", "a1x", "c"])
        XCTAssertEqual(groups[0].rows.map(\.depth), [0, 1, 2, 0])
        XCTAssertEqual(groups[1].rows.map(\.session.id), ["b"])
    }

    func testAForkWhoseParentIsntListedIsARoot() {
        let groups = HistoryTree.byProject([past("a1", parent: "gone"), past("self", parent: "self")])
        XCTAssertEqual(groups[0].rows.map(\.depth), [0, 0])
    }

    func testAChangeKeepsWhatItDoesntName() {
        let renamed = past("a").applying(HistoryChange(title: "Ship it"))
        XCTAssertEqual(renamed.title, "Ship it")
        XCTAssertEqual(renamed.customTitle, "Ship it")
        let pinned = renamed.applying(HistoryChange(pinned: true))
        XCTAssertTrue(pinned.isPinned)
        XCTAssertEqual(pinned.title, "Ship it")
        XCTAssertEqual(pinned.applying(HistoryChange(title: "")).customTitle, nil)
    }

    func testArchivingInTheDemoMovesTheRowToTheArchive() async throws {
        let sample = [past("a"), past("b")]
        let list = HistoryList(tools: MacTools(), archived: false, demo: sample)
        await list.refresh()
        try await list.change(list.sessions[0], HistoryChange(archived: true))
        XCTAssertEqual(list.sessions.map(\.id), ["b"])
        await list.refresh()
        XCTAssertEqual(list.sessions.map(\.id), ["b"])
    }
}
