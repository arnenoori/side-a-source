import Foundation
@testable import SideA
import Testing

@Test func warpPicksThePaneStillRunningTheSession() {
    let panes = [WarpFocus.Pane(window: 1, tab: 1, index: 0, cwd: "/r/api", lastFinished: 2_000),
                 WarpFocus.Pane(window: 1, tab: 2, index: 1, cwd: "/r/web", lastFinished: 2_000),
                 WarpFocus.Pane(window: 2, tab: 3, index: 0, cwd: "/r/web", lastFinished: 900)]
    // The web pane in window 1 ran a command after the session started, so the session isn't there.
    #expect(WarpFocus.pick(panes, cwd: "/r/web", started: 1_000)?.tab == 3)
    #expect(WarpFocus.pick(panes, cwd: "/r/web/", started: nil)?.tab == 2)
    #expect(WarpFocus.pick(panes, cwd: "/r/docs", started: 1_000) == nil)
    #expect(WarpFocus.date("2026-10-12 17:28:06.25") == 1_791_826_086.25)
}
