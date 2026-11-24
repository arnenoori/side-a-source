import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SideAProtocol

/// Clicks, scrolls and keys from the phone as CGEvents. macOS drops posted events unless Side A is allowed in
/// Accessibility, which only the person at the Mac can grant.
enum ScreenInput {
    static var trusted: Bool { ScreenStandIn.current?.accessibility ?? AXIsProcessTrusted() }

    static var locked: Bool {
        if let stand = ScreenStandIn.current { return stand.locked }
        return (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static var source: CGEventSource? { CGEventSource(stateID: .hidSystemState) }

    static func bounds(display: CGDirectDisplayID) -> CGRect { CGDisplayBounds(display) }

    static func bounds(window: CGWindowID) -> CGRect? {
        if let stand = ScreenStandIn.current { return stand.bounds(window: window) }
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?.first,
              let dictionary = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    static func frontWindow(of pid: pid_t) -> CGWindowID? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    static func owner(of window: CGWindowID) -> pid_t? {
        (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?.first?[kCGWindowOwnerPID as String] as? pid_t
    }

    static func focused(_ window: CGWindowID) -> Bool {
        if ScreenStandIn.current != nil { return true }
        guard let pid = owner(of: window) else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && frontWindow(of: pid) == window
    }

    /// Accessibility has no window numbers, so the window is found by its frame. Activation can be refused, which is why
    /// whoever asked checks `focused` afterwards.
    static func focus(_ window: CGWindowID) {
        guard ScreenStandIn.current == nil else { return }
        guard let pid = owner(of: window), let frame = bounds(window: window) else { return }
        let app = AXUIElementCreateApplication(pid)
        var list: AnyObject?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &list) == .success,
           let match = (list as? [AXUIElement])?.first(where: { self.frame(of: $0).map { near($0, frame) } ?? false }) {
            AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(match, kAXRaiseAction as CFString)
        }
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var position: AnyObject?, size: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        // swiftlint:disable force_cast -- the type IDs were checked just above.
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        // swiftlint:enable force_cast
        return CGRect(origin: origin, size: extent)
    }

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    static func click(_ point: CGPoint, kind: ScreenPointer.Kind) {
        if let stand = ScreenStandIn.current { return stand.post("\(kind.rawValue) \(Int(point.x)),\(Int(point.y))") }
        let right = kind == .rightClick
        let button: CGMouseButton = right ? .right : .left
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        for count in 1...(kind == .doubleClick ? 2 : 1) {
            for type: CGEventType in right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    /// The pointer moves there first: a scroll goes to whatever is under it.
    static func scroll(at point: CGPoint, dx: Double, dy: Double) {
        if let stand = ScreenStandIn.current { return stand.post("scroll \(Int(point.x)),\(Int(point.y)) by \(wheel(dx)),\(wheel(dy))") }
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: wheel(dy),
                wheel2: wheel(dx), wheel3: 0)?.post(tap: .cghidEventTap)
    }

    static func wheel(_ amount: Double) -> Int32 {
        amount.isFinite ? Int32(min(max(amount, -10_000), 10_000).rounded()) : 0
    }

    static func press(_ press: ScreenKeyPress) {
        guard let code = keyCode(press.key) else { return }
        if let stand = ScreenStandIn.current { return stand.post("key \(press.modifiers.map(\.rawValue).joined(separator: "+"))\(press.modifiers.isEmpty ? "" : "+")\(press.key.rawValue) code \(code)") }
        var flags = CGEventFlags()
        for modifier in press.modifiers {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            case .shift: flags.insert(.maskShift)
            default: break
            }
        }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Typed as Unicode rather than key codes, so it comes out the same whatever the Mac's keyboard layout.
    static func type(_ text: String) {
        if let stand = ScreenStandIn.current { return stand.post("text \(text.debugDescription)") }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.offset > 0 { press(ScreenKeyPress(key: .return)) }
            var units = Array(String(line.element).utf16)[...]
            while !units.isEmpty {
                // CGEvent carries at most 20 UTF-16 units.
                var chunk = Array(units.prefix(20))
                if chunk.count == 20, UTF16.isLeadSurrogate(chunk[19]) { chunk.removeLast() }
                units = units.dropFirst(chunk.count)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    event?.post(tap: .cghidEventTap)
                }
            }
        }
    }

    /// ANSI positions for shortcut letters: a shortcut names a key, not a character, so this follows the US layout.
    static func keyCode(_ key: ScreenKey) -> CGKeyCode? {
        switch key {
        case .return: return 36
        case .tab: return 48
        case .space: return 49
        case .delete: return 51
        case .escape: return 53
        case .forwardDelete: return 117
        case .home: return 115
        case .end: return 119
        case .pageUp: return 116
        case .pageDown: return 121
        case .left: return 123
        case .right: return 124
        case .down: return 125
        case .up: return 126
        default: return letters[key.rawValue]
        }
    }

    private static let letters: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
    ]
}
