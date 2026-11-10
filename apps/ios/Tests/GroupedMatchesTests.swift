import XCTest
@testable import SideARemote

@MainActor
final class GroupedMatchesTests: XCTestCase {
    func testGroupsLinesByFile() {
        let groups = GroupedMatches.group("a.swift:3\nb.swift:9\na.swift:12")
        XCTAssertEqual(groups.map(\.file), ["a.swift", "b.swift"])
        XCTAssertEqual(groups.first?.lines, ["3", "12"])
    }

    func testABareColonIsSkipped() {
        let groups = GroupedMatches.group(":\na.swift:1\n:")
        XCTAssertEqual(groups.map(\.file), ["a.swift"])
    }
}
