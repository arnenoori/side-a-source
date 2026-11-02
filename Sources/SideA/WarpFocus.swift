import AppKit
import ApplicationServices
import Darwin
import SQLite3
import SideACore

/// Warp has no scripting API for tabs: its session-restore database and Accessibility window titles stand in for one.
enum WarpFocus {
    struct Pane: Equatable {
        let window: Int
        let tab: Int
        let index: Int
        let cwd: String?
        let lastFinished: Double?
    }

    struct Window: Equatable {
        let id: Int
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    static func show(_ host: TerminalFocus.Host, cwd: String?, title: String?) -> String? {
        // Warp gives each shell a link to its own pane; the session inherits it, so this finds the exact tab and split.
        if let url = focusURL(host.session), NSWorkspace.shared.open(url) { return nil }
        guard AXIsProcessTrusted() else {
            _ = NSRunningApplication(processIdentifier: host.pid)?.activate()
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return "To open the exact Warp tab, allow Side A in System Settings > Privacy & Security > Accessibility."
        }
        let app = AXUIElementCreateApplication(host.pid)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        // A title only counts when one window has it; a common one could belong to another tab.
        if let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            let titled = windows.filter { (attribute($0, kAXTitleAttribute) as? String)?.localizedCaseInsensitiveContains(title) == true }
            if titled.count == 1 {
                raise(titled[0], host)
                return nil
            }
        }
        guard let cwd, let (panes, frames) = read(bundleID: host.bundleID),
              let pane = pick(panes, cwd: cwd, started: ProcessEnvironment.started(pid: host.session)),
              let frame = frames.first(where: { $0.id == pane.window }),
              let window = windows.first(where: { matches($0, frame) }) else {
            return NSRunningApplication(processIdentifier: host.pid)?.activate() == true ? nil : "Warp could not be brought forward."
        }
        raise(window, host)
        let count = panes.filter { $0.window == pane.window }.map(\.tab).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }.count
        // Warp: ⌘1–⌘8 pick a tab by position and ⌘9 the last one.
        let digit = pane.index < 8 ? pane.index + 1 : pane.index == count - 1 ? 9 : nil
        guard let digit else { return "Side A raised the Warp window; the session is in tab \(pane.index + 1)." }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { press(digit, in: host.pid) }
        return nil
    }

    static func focusURL(_ pid: pid_t) -> URL? {
        ProcessEnvironment.read(pid: pid)?["WARP_FOCUS_URL"]
            .flatMap(URL.init(string:)).flatMap { $0.scheme?.hasPrefix("warp") == true ? $0 : nil }
    }

    static func pick(_ panes: [Pane], cwd: String, started: Double?) -> Pane? {
        let here = panes.filter { $0.cwd.map(normalize) == normalize(cwd) }
        let running = here.filter { pane in started.map { start in (pane.lastFinished ?? 0) <= start + 1 } ?? true }
        return running.first ?? here.first
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func read(bundleID: String) -> ([Pane], [Window])? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/\(bundleID)/warp.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        let panes = rows(db, """
            SELECT t.window_id, t.id, tp.cwd,
                   (SELECT MAX(b.completed_ts) FROM blocks b WHERE b.pane_leaf_uuid = tp.uuid)
            FROM tabs t JOIN pane_nodes pn ON pn.tab_id = t.id JOIN terminal_panes tp ON tp.id = pn.id
            ORDER BY t.window_id, t.id
            """) { statement in
            (Int(sqlite3_column_int64(statement, 0)), Int(sqlite3_column_int64(statement, 1)),
             text(statement, 2), text(statement, 3).flatMap(date))
        }
        var order: [Int: [Int]] = [:]
        for pane in panes where order[pane.0]?.contains(pane.1) != true { order[pane.0, default: []].append(pane.1) }
        let windows = rows(db, "SELECT id, origin_x, origin_y, window_width, window_height FROM windows") { statement in
            Window(id: Int(sqlite3_column_int64(statement, 0)), x: sqlite3_column_double(statement, 1), y: sqlite3_column_double(statement, 2),
                   width: sqlite3_column_double(statement, 3), height: sqlite3_column_double(statement, 4))
        }
        guard !panes.isEmpty else { return nil }
        return (panes.map { Pane(window: $0.0, tab: $0.1, index: order[$0.0]?.firstIndex(of: $0.1) ?? 0, cwd: $0.2, lastFinished: $0.3) }, windows)
    }

    private static func rows<T>(_ db: OpaquePointer?, _ sql: String, _ row: (OpaquePointer?) -> T) -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(row(statement)) }
        return result
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    /// Warp stores UTC times as "2026-10-12 17:28:06.292331".
    static func date(_ value: String) -> Double? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let parts = value.split(separator: ".", maxSplits: 1)
        guard let seconds = formatter.date(from: String(parts[0]))?.timeIntervalSince1970 else { return nil }
        return seconds + (parts.count > 1 ? Double("0." + parts[1]) ?? 0 : 0)
    }

    /// Warp saves window origins with y measured from the top of the main display, minus its height.
    private static func matches(_ window: AXUIElement, _ frame: Window) -> Bool {
        var position = CGPoint.zero, size = CGSize.zero
        guard let p = attribute(window, kAXPositionAttribute), let s = attribute(window, kAXSizeAttribute) else { return false }
        AXValueGetValue(p as! AXValue, .cgPoint, &position)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return abs(position.x - frame.x) < 2 && abs(size.width - frame.width) < 2 && abs(size.height - frame.height) < 2
            && abs(position.y - mainHeight - frame.y) < 2
    }

    private static func raise(_ window: AXUIElement, _ host: TerminalFocus.Host) {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: host.pid)?.activate()
    }

    private static func press(_ digit: Int, in pid: pid_t) {
        let codes = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(codes[digit - 1]), keyDown: down)
            event?.flags = .maskCommand
            event?.postToPid(pid)
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
