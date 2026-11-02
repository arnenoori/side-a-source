import Darwin
import Foundation

/// Another process's environment, which says which login a session reads and which Codex home it writes.
public enum ProcessEnvironment {
    /// nil when the process has exited or belongs to another user.
    public static func read(pid: pid_t) -> [String: String]? {
        procargs(pid).map(parse)
    }

    public static func arguments(pid: pid_t) -> [String] {
        procargs(pid).map(arguments) ?? []
    }

    private static func procargs(_ pid: pid_t) -> Data? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard pid > 0, sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Data(buffer.prefix(size))
    }

    public static func arguments(_ procargs: Data) -> [String] {
        guard procargs.count > 4 else { return [] }
        let argc = Int(procargs.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc >= 0 else { return [] }
        return procargs.dropFirst(4).split(separator: 0).dropFirst().prefix(argc).map { String(decoding: $0, as: UTF8.self) }
    }

    /// What a process runs, by name: the script a shell or interpreter runs, else the program.
    public static func origin(_ arguments: [String]) -> String? {
        guard let first = arguments.first else { return nil }
        let program = String(((first as NSString).lastPathComponent).drop { $0 == "-" })
        let rest = Array(arguments.dropFirst())
        let shells: Set = ["sh", "bash", "zsh", "dash", "fish"]
        let interpreters: Set = ["node", "bun", "deno", "ruby", "perl", "osascript"]
        let name = { (path: Substring) in (String(path) as NSString).lastPathComponent }
        if shells.contains(program),
           let flag = rest.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }), flag + 1 < rest.count,
           let command = rest[flag + 1].split(whereSeparator: \.isWhitespace).first(where: { !$0.contains("=") }) {
            return name(command)
        }
        guard shells.contains(program) || interpreters.contains(program) || program.hasPrefix("python"),
              let script = rest.first(where: { !$0.hasPrefix("-") }) else { return program }
        return name(Substring(script))
    }

    /// KERN_PROCARGS2: argc, the executable path, padding, argv, then the environment, all NUL-separated.
    public static func parse(_ procargs: Data) -> [String: String] {
        guard procargs.count > 4 else { return [:] }
        let argc = Int(procargs.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        let parts = procargs.dropFirst(4).split(separator: 0)
        guard argc >= 0, parts.count > argc + 1 else { return [:] }
        var environment: [String: String] = [:]
        for entry in parts.dropFirst(argc + 1) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "=") else { continue }
            environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return environment
    }

    public static func started(pid: pid_t) -> Double? { ProcessCheck.startTime(Int(pid)) }

    /// Claude Code's rule, as island_hook.py and sidea_bridge.py apply it: "mac" for the Mac login.
    public static func claudeSlot(_ env: [String: String]) -> String {
        let store = env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] ?? env["CLAUDE_CONFIG_DIR"] ?? ""
        let name = store.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? "mac" : name
    }

    public enum CodexHome: Equatable, Sendable { case mac, profile(String), other(String) }

    /// `root` is Side A's folder, whose `profiles/<uuid>` hold each Codex account's home.
    public static func codexHome(_ env: [String: String], root: String, home: String) -> CodexHome {
        guard let value = env["CODEX_HOME"], !value.isEmpty else { return .mac }
        let path = standard(value)
        if path == standard(home + "/.codex") { return .mac }
        let profiles = standard(root + "/profiles") + "/"
        if path.hasPrefix(profiles) {
            let rest = path.dropFirst(profiles.count)
            if !rest.isEmpty, !rest.contains("/") { return .profile(String(rest)) }
        }
        return .other(value)
    }

    private static func standard(_ path: String) -> String {
        let trimmed = URL(fileURLWithPath: path).standardizedFileURL.path
        return trimmed.count > 1 && trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }
}
