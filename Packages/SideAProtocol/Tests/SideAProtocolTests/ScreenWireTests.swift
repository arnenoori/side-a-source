import Foundation
import SideAProtocol
import Testing

@Test func everyScreenControlSurvivesTheWire() throws {
    let controls: [ScreenControl] = [
        .hello(ScreenHello(maxWidth: 2560, maxHeight: 2560)), .start(ScreenStart()), .start(ScreenStart(target: .window(7), fps: 15, session: "sa-1")),
        .start(ScreenStart(target: .display(1))), .keyframe, .feedback(ScreenFeedback(fps: 29.5, dropped: 1, rtt: 12)), .ping(t: 1.5),
        .pointer(ScreenPointer(kind: .rightClick, x: 0.25, y: 0.75)), .scroll(ScreenScroll(x: 0.5, y: 0.5, dx: 0, dy: -0.1)),
        .key(ScreenKeyPress(key: .escape, modifiers: [.command])), .text("hi"), .bye,
        .ready(ScreenReady(route: .direct, displays: [ScreenDisplay(id: 1, name: "D", width: 1440, height: 900, main: true)],
                           windows: [ScreenWindow(id: 7, app: "Terminal", title: nil, width: 900, height: 600)],
                           control: ScreenControlState(allowed: false, reason: .view), limits: .direct)),
        .started(ScreenStarted(target: .display(1), width: 2880, height: 1800, fps: 30)),
        .quality(ScreenQuality(fps: 15, bitrate: 1_500_000, width: 1280, height: 800, reduced: true)),
        .control(ScreenControlState(allowed: true)), .pong(t: 1.5), .refused(ScreenRefused(reason: .off, message: "off")),
    ]
    for control in controls {
        let data = try JSONEncoder().encode(control)
        #expect(try JSONDecoder().decode(ScreenControl.self, from: data) == control, "\(control.type)")
    }
}
