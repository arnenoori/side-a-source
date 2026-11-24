import CoreGraphics
import CoreVideo
import Foundation
import SideAProtocol

/// Set only by the Remote test harness: a screen, windows and permissions that need no person at the Mac, so the whole
/// Screen flow can be run where Screen Recording and Accessibility can't be granted. The app never sets `current`, and
/// every place that reads it behaves as it always did while it is nil.
final class ScreenStandIn: @unchecked Sendable {
    nonisolated(unsafe) static var current: ScreenStandIn?

    struct Window { let info: ScreenWindow; let bounds: CGRect }

    private let lock = NSLock()
    private var flags = (recording: true, accessibility: true, locked: false)
    private var log: [String] = []
    let displays: [ScreenDisplay]
    let windows: [Window]
    /// Draws tick `n` into a pixel buffer, given the last inputs this stand-in took, so a click shows up in the picture.
    var draw: (CVPixelBuffer, Int, [String], CGRect) -> Void = { _, _, _, _ in }
    /// Where the picture being captured sits, in the same points the posted inputs use.
    var shown: CGRect { get { lock.withLock { place } } set { lock.withLock { place = newValue } } }
    private var place = CGRect.zero
    var onPost: ((String) -> Void)?

    init(displays: [ScreenDisplay], windows: [Window]) { self.displays = displays; self.windows = windows }

    var recording: Bool { get { lock.withLock { flags.recording } } set { lock.withLock { flags.recording = newValue } } }
    var accessibility: Bool { get { lock.withLock { flags.accessibility } } set { lock.withLock { flags.accessibility = newValue } } }
    var locked: Bool { get { lock.withLock { flags.locked } } set { lock.withLock { flags.locked = newValue } } }

    /// What the Mac would have posted, as a line each.
    func post(_ line: String) {
        lock.withLock { log.append(line) }
        onPost?(line)
    }

    var posted: [String] { lock.withLock { log } }

    func bounds(display id: UInt32) -> CGRect {
        let match = displays.first { $0.id == id } ?? displays[0]
        return CGRect(x: 0, y: 0, width: match.width, height: match.height)
    }

    func bounds(window id: UInt32) -> CGRect? { windows.first { $0.info.id == id }?.bounds }
}

/// Where the Mac's Screen Recording permission is read: the system's, unless a harness stands in.
enum ScreenAccess {
    static var recording: Bool { ScreenStandIn.current?.recording ?? CGPreflightScreenCaptureAccess() }
}
