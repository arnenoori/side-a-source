import Crypto
import Foundation
import SideACore
import SideAProtocol

/// What the phone is told about the machine, and where the daemon may listen.
public enum HostInfo {
    /// `.wsl` inside Windows Subsystem for Linux, `.linux` elsewhere on Linux; a Mac running the daemon (tests, development)
    /// says `.macos`.
    public static func detectOS(environment: [String: String] = ProcessInfo.processInfo.environment,
                                procVersion: String? = try? String(contentsOfFile: "/proc/version", encoding: .utf8)) -> HostOS {
        #if os(Linux)
        if environment["WSL_DISTRO_NAME"] != nil || procVersion?.lowercased().contains("microsoft") == true { return .wsl }
        return .linux
        #else
        return .macos
        #endif
    }

    /// A stable id for this machine: the first 8 bytes of the SHA-256 of `/etc/machine-id`, else of the host name, in hex.
    public static func machineID() -> String {
        let seed = (try? String(contentsOfFile: "/etc/machine-id", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = seed.flatMap { $0.isEmpty ? nil : $0 } ?? ProcessInfo.processInfo.hostName
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func hostName() -> String {
        let name = ProcessInfo.processInfo.hostName
        return name.split(separator: ".").first.map(String.init) ?? name
    }

    /// `tailscale status --json`, read only, with a deadline. Nothing in tailscaled changes.
    public static func tailscale(timeout: TimeInterval = 3) -> TailscaleStatus {
        let candidates = ["/usr/bin/tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return TailscaleStatus(state: .notInstalled) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("sidead-ts-\(UUID().uuidString.prefix(8)).json")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let sink = try? FileHandle(forWritingTo: output) else { return TailscaleStatus(state: .stopped) }
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["status", "--json"]
        process.standardOutput = sink
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return TailscaleStatus(state: .stopped) }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return TailscaleStatus(state: .stopped) }
        return TailscaleStatus.parse((try? Data(contentsOf: output)) ?? Data())
    }
}
