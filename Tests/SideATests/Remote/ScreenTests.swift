import CoreGraphics
import Foundation
@testable import SideA
import SideAProtocol
import Testing

@Suite("Screen", .serialized)
@MainActor
struct ScreenTests {
    @Test func aPictureIsFittedWithinTheLongEdgeAndEvenOnBothSides() {
        #expect(ScreenCapture.fit(width: 3024, height: 1964, longEdge: 1600) == ScreenCapture.Size(width: 1600, height: 1038))
        #expect(ScreenCapture.fit(width: 1000, height: 501, longEdge: 1600) == ScreenCapture.Size(width: 1000, height: 500))
        #expect(ScreenCapture.fit(width: 0, height: 0, longEdge: 1600) == ScreenCapture.Size(width: 2, height: 2))
        let tall = ScreenCapture.fit(width: 900, height: 3001, longEdge: 1280)
        #expect(tall.height <= 1280 && tall.width.isMultiple(of: 2) && tall.height.isMultiple(of: 2))
    }

    @Test func aScrollAmountFromThePhoneIsClampedAndNeverNotANumber() {
        #expect(ScreenInput.wheel(.nan) == 0)
        #expect(ScreenInput.wheel(.infinity) == 0)
        #expect(ScreenInput.wheel(1e12) == 10_000)
        #expect(ScreenInput.wheel(-1e12) == -10_000)
        #expect(ScreenInput.wheel(12.6) == 13)
    }

    @Test func everyNamedKeyAndEveryLowercaseLetterHasACode() {
        let named: [ScreenKey] = [.return, .escape, .tab, .space, .delete, .forwardDelete, .left, .right, .up, .down, .home, .end, .pageUp, .pageDown]
        for key in named { #expect(ScreenInput.keyCode(key) != nil, "\(key.rawValue)") }
        for letter in "abcdefghijklmnopqrstuvwxyz0123456789" { #expect(ScreenInput.keyCode(ScreenKey(rawValue: String(letter))) != nil, "\(letter)") }
        #expect(ScreenInput.keyCode(ScreenKey(rawValue: "unknown")) == nil)
        #expect(ScreenInput.keyCode(.escape) == 53 && ScreenInput.keyCode(.tab) == 48 && ScreenInput.keyCode(ScreenKey(rawValue: "c")) == 8)
    }

    @Test func withAStandInInputIsWrittenDownNotPosted() {
        let stand = ScreenStandIn(displays: [ScreenDisplay(id: 1, name: "D", width: 100, height: 50, main: true)], windows: [])
        ScreenStandIn.current = stand
        defer { ScreenStandIn.current = nil }
        ScreenInput.click(CGPoint(x: 10, y: 20), kind: .click)
        ScreenInput.click(CGPoint(x: 11, y: 21), kind: .rightClick)
        ScreenInput.scroll(at: CGPoint(x: 5, y: 6), dx: .nan, dy: 40)
        ScreenInput.press(ScreenKeyPress(key: .escape))
        ScreenInput.press(ScreenKeyPress(key: ScreenKey(rawValue: "c"), modifiers: [.command, .shift]))
        ScreenInput.type("hi")
        #expect(stand.posted == ["click 10,20", "rightClick 11,21", "scroll 5,6 by 0,40", "key escape code 53", "key command+shift+c code 8", #"text "hi""#])
    }

    @Test func aStandInsPermissionsReplaceTheSystems() {
        let stand = ScreenStandIn(displays: [ScreenDisplay(id: 1, name: "D", width: 100, height: 50, main: true)], windows: [])
        ScreenStandIn.current = stand
        defer { ScreenStandIn.current = nil }
        #expect(ScreenAccess.recording && ScreenInput.trusted && !ScreenInput.locked)
        stand.recording = false
        stand.accessibility = false
        stand.locked = true
        #expect(!ScreenAccess.recording && !ScreenInput.trusted && ScreenInput.locked)
    }

    @Test func aReportThatCameLateIsDroppedSoTheWatcherNeverOutlivesTheSocket() {
        let share = ScreenShare()
        share.began(device: "a", mode: .view, route: .direct, order: 1)
        #expect(share.watcher?.device == "a")
        share.ended(device: "a", order: 2)
        #expect(share.watcher == nil)
        share.began(device: "a", mode: .view, route: .direct, order: 1)
        #expect(share.watcher == nil)
        share.began(device: "b", mode: .control, route: .relay, order: 4)
        share.ended(device: "a", order: 3)
        #expect(share.watcher?.device == "b" && share.watcher?.route == .relay)
    }

    @Test func everyRefusalHasItsOwnCodeAndWordsThatNameTheFix() {
        let codes = ScreenClose.refusals.map(\.closeCode)
        #expect(Set(codes).count == codes.count)
        #expect(ScreenRefusal.off.message.contains("Settings"))
        #expect(ScreenRefusal.permission.message.contains("Screen Recording"))
        #expect(ScreenRefusal.replaced.message.contains("Another device"))
    }

    @Test func aStillLanScreenAtItsStartingRateIsNotCalledReduced() {
        let start = ScreenLimits.direct.bitrate * 2 / 5
        #expect(!ScreenViewer.reduced(bitrate: start, on: .direct))
        #expect(!ScreenViewer.reduced(bitrate: ScreenLimits.direct.bitrate, on: .direct))
        #expect(ScreenViewer.reduced(bitrate: start - 1, on: .direct))
        #expect(ScreenViewer.reduced(bitrate: ScreenLimits.relay.bitrate, on: .relay))
    }
}
