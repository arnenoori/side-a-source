import CoreText
import CoreGraphics
import CoreVideo
import Foundation
@testable import SideA
import SideAProtocol

/// SIDEA_HARNESS_SCREEN=<command file>: Screen without a person at the Mac. A made-up display and a made-up Terminal window
/// go through the real encoder, hub and socket, and the clicks and keys the phone sends are written down, with a red mark
/// at each click in the picture, instead of being posted, so neither Screen Recording nor Accessibility is needed. Write
/// lines into the command file to change the Mac: `off`, `on`, `control on|off`, `recording yes|no`, `access yes|no`,
/// `locked yes|no`, `end [off|permission|replaced|ended|timeout|failed]`, `dump`.
enum HarnessScreen {
    nonisolated(unsafe) static let display = ScreenDisplay(id: 1, name: "Harness Display", width: 1440, height: 900, main: true)
    nonisolated(unsafe) static let window = ScreenStandIn.Window(info: ScreenWindow(id: 7, app: "Terminal", title: "claude · side-a", width: 900, height: 600),
                                             bounds: CGRect(x: 200, y: 100, width: 900, height: 600))

    @MainActor static func install(_ remote: RemoteController, say: @escaping (String) -> Void) -> ScreenStandIn {
        let stand = ScreenStandIn(displays: [display], windows: [window])
        stand.draw = { buffer, tick, posted, shown in Self.paint(buffer, tick, posted, shown) }
        // Called on the server's queue, where the harness loop's own `say` (main actor) can't be.
        stand.onPost = { line in FileHandle.standardError.write(Data("HARNESS INPUT \(line)\n".utf8)) }
        ScreenStandIn.current = stand
        return stand
    }

    @MainActor static func poll(_ file: String?, _ stand: ScreenStandIn, _ remote: RemoteController, watching: inout ScreenShare.Watcher?,
                                say: (String) -> Void) {
        if let file, let text = try? String(contentsOfFile: file, encoding: .utf8), !text.isEmpty {
            try? FileManager.default.removeItem(atPath: file)
            for line in text.split(separator: "\n") { command(String(line), stand, remote, say: say) }
        }
        guard remote.screen.watcher != watching else { return }
        watching = remote.screen.watcher
        say("watcher \(watching.map { "\($0.name) \($0.mode.rawValue) over \($0.route.rawValue)" } ?? "none")")
    }

    @MainActor static func command(_ line: String, _ stand: ScreenStandIn, _ remote: RemoteController, say: (String) -> Void) {
        let words = line.split(separator: " ").map(String.init)
        let yes = words.last == "yes" || words.last == "on"
        switch words.first {
        case "on": volatile(ScreenShare.enabledKey, true); remote.screen.setOn(true)
        case "off": volatile(ScreenShare.enabledKey, false); remote.screen.setOn(false)
        case "control": volatile(ScreenShare.controlKey, yes); remote.screen.setControl(yes)
        case "recording": stand.recording = yes
        case "access": stand.accessibility = yes
        case "locked": stand.locked = yes
        case "end": remote.screen.end(words.count > 1 ? ScreenRefusal(rawValue: words[1]) : .ended)
        case "dump": say("INPUTS \(stand.posted)")
        default: say("unknown screen command \(line)")
        }
        remote.screen.refresh()
        say("screen command \(line)")
    }

    /// The harness's switches live in the argument domain, which a saved value can't override.
    private static func volatile(_ key: String, _ value: Bool) {
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        domain[key] = value
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    private nonisolated static func paint(_ buffer: CVPixelBuffer, _ tick: Int, _ posted: [String], _ shown: CGRect) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let w = CGFloat(width), h = CGFloat(height)
        zoomGrid(context, w, h)
        frameMarker(context, w, h, tick)
        let size = h / 20
        let title = shown.width == 900 ? "TERMINAL WINDOW" : "WHOLE DISPLAY"
        text("\(title)  \(width)x\(height)  frame \(tick)", at: CGPoint(x: w * 0.04, y: h * 0.5), size: size, color: CGColor(gray: 1, alpha: 1), in: context)
        let log = posted.filter { !$0.hasPrefix("click") && !$0.hasPrefix("rightClick") && !$0.hasPrefix("doubleClick") }.suffix(4)
        for (index, line) in log.enumerated() {
            text(line, at: CGPoint(x: w * 0.04, y: h * (0.38 - 0.08 * Double(index))), size: size * 0.7, color: CGColor(red: 1, green: 1, blue: 0, alpha: 1), in: context)
        }
        clickMarks(context, w, h, posted, shown)
    }

    private nonisolated static func zoomGrid(_ context: CGContext, _ w: CGFloat, _ h: CGFloat) {
        context.setFillColor(CGColor(red: 0.07, green: 0.09, blue: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setStrokeColor(CGColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1))
        context.setLineWidth(max(1, w / 800))
        let step = w / 14
        for x in stride(from: 0, through: w, by: step) { context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: h)) }
        for y in stride(from: 0, through: h, by: step) { context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: w, y: y)) }
        context.strokePath()
    }

    /// A square that crosses the frame every 120 ticks, so a stalled stream shows as a square that stops.
    private nonisolated static func frameMarker(_ context: CGContext, _ w: CGFloat, _ h: CGFloat, _ tick: Int) {
        let phase = Double(tick % 120) / 120
        context.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: (w - h / 6) * phase, y: h * 0.1, width: h / 6, height: h / 6))
    }

    private nonisolated static func clickMarks(_ context: CGContext, _ w: CGFloat, _ h: CGFloat, _ posted: [String], _ shown: CGRect) {
        guard shown.width > 0 else { return }
        for line in posted where line.hasPrefix("click") || line.hasPrefix("rightClick") || line.hasPrefix("doubleClick") {
            let numbers = line.split(separator: " ")[1].split(separator: ",").compactMap { Double($0) }
            guard numbers.count == 2 else { continue }
            let x = (numbers[0] - shown.minX) / shown.width * w, y = h - (numbers[1] - shown.minY) / shown.height * h
            context.setFillColor(line.hasPrefix("rightClick") ? CGColor(red: 1, green: 0.8, blue: 0, alpha: 1) : CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1))
            context.fillEllipse(in: CGRect(x: x - h / 40, y: y - h / 40, width: h / 20, height: h / 20))
        }
    }

    private nonisolated static func text(_ string: String, at point: CGPoint, size: CGFloat, color: CGColor, in context: CGContext) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, string as CFString, attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
