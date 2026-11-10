import AppKit
import Darwin
import SideACore

enum TerminalFocus {
    struct Host: Sendable {
        let app: String
        let bundleID: String
        let pid: pid_t
        let tty: String?
        /// The session's own process, under the terminal.
        var session: pid_t = 0
    }

    static func host(of pid: Int) -> Host? {
        let tty = info(pid_t(pid))?.tty
        var current = pid_t(pid)
        for _ in 0..<32 {
            guard let parent = info(current)?.parent, parent > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent), let bundleID = app.bundleIdentifier, app.activationPolicy == .regular {
                return Host(app: app.localizedName ?? "Terminal", bundleID: bundleID, pid: parent, tty: tty, session: pid_t(pid))
            }
            current = parent
        }
        return nil
    }

    static func show(_ host: Host, cwd: String?, title: String?) async -> String? {
        let script: String
        let arguments: [String]
        switch host.bundleID {
        case "com.apple.Terminal":
            guard let tty = host.tty else { return activate(host) }
            script = """
            on run argv
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is (item 1 of argv) then
                                set selected of t to true
                                set index of w to 1
                                activate
                                return
                            end if
                        end repeat
                    end repeat
                    activate
                end tell
            end run
            """
            arguments = [tty]
        case "com.googlecode.iterm2":
            guard let tty = host.tty else { return activate(host) }
            script = """
            on run argv
                tell application "iTerm"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is (item 1 of argv) then
                                    select w
                                    select t
                                    select s
                                    activate
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                    activate
                end tell
            end run
            """
            arguments = [tty]
        case "com.mitchellh.ghostty":
            // Ghostty does not expose a terminal's tty; the folder and the title Claude Code sets identify it.
            script = """
            on run argv
                tell application "Ghostty"
                    set best to missing value
                    set sameFolder to {}
                    repeat with t in terminals
                        if working directory of t is (item 1 of argv) then
                            set end of sameFolder to t
                            if (item 2 of argv) is not "" and name of t contains (item 2 of argv) then set best to t
                        end if
                    end repeat
                    if best is missing value and (count of sameFolder) is 1 then set best to item 1 of sameFolder
                    if best is not missing value then focus best
                    activate
                end tell
            end run
            """
            arguments = [cwd ?? "", title ?? ""]
        case "net.kovidgoyal.kitty":
            // Needs remote control with a listen_on socket; without one the app only comes forward.
            let env = ProcessEnvironment.read(pid: host.session) ?? [:]
            if let socket = env["KITTY_LISTEN_ON"], let window = env["KITTY_WINDOW_ID"], let tool = tool(host, "kitty") {
                _ = await HostedSessions.process(tool, ["@", "--to", socket, "focus-window", "--match", "id:\(window)"], timeout: 5)
            }
            return activate(host)
        case "com.github.wez.wezterm":
            let env = ProcessEnvironment.read(pid: host.session) ?? [:]
            if let pane = env["WEZTERM_PANE"], let tool = tool(host, "wezterm") {
                _ = await HostedSessions.process(tool, ["cli", "activate-pane", "--pane-id", pane],
                                                 environment: env.filter { $0.key == "WEZTERM_UNIX_SOCKET" }, timeout: 5)
            }
            return activate(host)
        case let id where id.hasPrefix("dev.warp.Warp"):
            return await MainActor.run { WarpFocus.show(host, cwd: cwd, title: title) }
        default:
            return activate(host)
        }
        return await run(script, arguments)
    }

    private static func tool(_ host: Host, _ name: String) -> String? {
        let path = NSRunningApplication(processIdentifier: host.pid)?.bundleURL?.appendingPathComponent("Contents/MacOS/\(name)").path
        return path.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    private static func activate(_ host: Host) -> String? {
        NSRunningApplication(processIdentifier: host.pid)?.activate() == true ? nil : "\(host.app) could not be brought forward."
    }

    static let automationDenied = "Allow Side A to control your terminal in System Settings > Privacy & Security > Automation."

    /// No timeout: osascript waits while macOS asks whether Side A may control the terminal.
    private static func run(_ script: String, _ arguments: [String]) async -> String? {
        let run = await ProcessRunner.run("/usr/bin/osascript", ["-e", script] + arguments, timeout: nil)
        if run.launchError != nil { return "The terminal could not be reached." }
        guard run.status != 0 else { return nil }
        let message = String(data: run.errors, encoding: .utf8) ?? ""
        return message.contains("-1743") ? automationDenied
            : "The terminal tab could not be found."
    }

    /// A pane on the user's own tmux server, found by the session's tty. Sessions go by id: a name can read as one.
    struct TmuxPane: Sendable {
        let tmux: String
        let socket: String
        let session: String
        let window: String
        let pane: String
        let clients: [pid_t]

        var attach: String { [tmux, "-u", "-S", socket, "attach-session", "-t", session].map(Shell.quote).joined(separator: " ") }

        /// A window linked into several sessions is selected in this one.
        func select() async {
            _ = await HostedSessions.process(tmux, ["-u", "-S", socket, "select-window", "-t", "\(session):\(window)", ";", "select-pane", "-t", pane], timeout: 5)
        }
    }

    /// -u: without a UTF-8 locale (an app started by launchd has none) tmux prints tabs in formats as '_'.
    static func tmuxPane(of pid: Int) async -> TmuxPane? {
        guard let tty = info(pid_t(pid))?.tty, let server = tmuxServer(above: pid_t(pid)), let tmux = path(server) else { return nil }
        let folders = Set([ProcessInfo.processInfo.environment["TMUX_TMPDIR"], "/private/tmp"].compactMap { $0 }.map { "\($0)/tmux-\(getuid())" })
        for folder in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                let socket = "\(folder)/\(name)"
                let panes = await HostedSessions.process(tmux, ["-u", "-S", socket, "list-panes", "-a", "-F", "#{pane_tty}\t#{session_id}\t#{window_id}\t#{pane_id}"], timeout: 5)
                guard let line = panes.output.split(separator: "\n").map({ $0.split(separator: "\t", omittingEmptySubsequences: false) })
                    .first(where: { $0.count == 4 && $0[0] == tty }) else { continue }
                let session = String(line[1])
                let listed = await HostedSessions.process(tmux, ["-u", "-S", socket, "list-clients", "-t", session, "-F", "#{client_activity}\t#{client_pid}"], timeout: 5)
                let clients = listed.output.split(separator: "\n").compactMap { row -> (Double, pid_t)? in
                    let parts = row.split(separator: "\t")
                    guard parts.count == 2, let pid = pid_t(parts[1]) else { return nil }
                    return (Double(parts[0]) ?? 0, pid)
                }.sorted { $0.0 > $1.0 }.map(\.1)
                return TmuxPane(tmux: tmux, socket: socket, session: session, window: String(line[2]), pane: String(line[3]), clients: clients)
            }
        }
        return nil
    }

    /// For a run with no terminal and no app above it: what started it, such as a script launchd or cron runs. One an
    /// app started (VS Code, the Claude app) still has that app to show.
    static func origin(of pid: Int) -> String? {
        guard let process = info(pid_t(pid)), process.tty == nil, host(of: pid) == nil else { return nil }
        guard process.parent > 1 else { return "launchd" }
        return ProcessEnvironment.origin(ProcessEnvironment.arguments(pid: process.parent)) ?? "a background job"
    }

    /// Why a session has no tab on this Mac to show.
    static func whereabouts(of pid: Int) -> String {
        if let origin = origin(of: pid) { return "It's an automated run started by \(origin), so it has no terminal." }
        var current = pid_t(pid)
        for _ in 0..<32 {
            guard let parent = info(current)?.parent, parent > 1 else { break }
            // macOS runs each login under sshd-session, older releases under sshd.
            if path(parent).map({ ($0 as NSString).lastPathComponent.hasPrefix("sshd") }) == true {
                let from = ProcessEnvironment.read(pid: pid_t(pid))?["SSH_CONNECTION"]?.split(separator: " ").first.map { " from \($0)" } ?? ""
                return "It runs in an SSH login\(from), so there's no tab on this Mac to show."
            }
            current = parent
        }
        return "Its terminal could not be found. The session may have closed."
    }

    static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    private static func tmuxServer(above pid: pid_t) -> pid_t? {
        var current = pid
        for _ in 0..<32 {
            guard let parent = info(current)?.parent, parent > 1 else { return nil }
            if path(parent).map({ ($0 as NSString).lastPathComponent }) == "tmux" { return parent }
            current = parent
        }
        return nil
    }

    private static func path(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func info(_ pid: pid_t) -> (parent: pid_t, tty: String?)? {
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &process, &size, nil, 0) == 0, size > 0 else { return nil }
        let device = process.kp_eproc.e_tdev
        let tty = device == -1 ? nil : devname(device, S_IFCHR).map { "/dev/" + String(cString: $0) }
        return (process.kp_eproc.e_ppid, tty)
    }
}
