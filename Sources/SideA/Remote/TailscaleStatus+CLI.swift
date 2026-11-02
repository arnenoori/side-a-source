import Foundation
import SideACore
import SideAKeepAwakeCore

/// The Tailscale CLI, found once and remembered. Read only: Side A never changes tailscaled.
actor TailscaleCLI {
    static let shared = TailscaleCLI()
    private static let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
    private var path: String?

    func status() async -> TailscaleStatus {
        guard let path = await find() else { return TailscaleStatus(state: .notInstalled) }
        guard let output = await Self.run(path, ["status", "--json"]) else { return TailscaleStatus(state: .stopped) }
        var status = TailscaleStatus.parse(output.stdout)
        // Stopped prints its state on stderr and an empty Self; the backend state is still in the JSON when there is any.
        if output.stdout.isEmpty { status.state = .stopped }
        return status
    }

    var location: String? { path }

    /// The Tailscale login of the device at `address`, from tailscaled's own record of the peer.
    func whois(_ address: String) async -> String? {
        guard let path = await find(), let output = await Self.run(path, ["whois", "--json", address]), output.status == 0 else { return nil }
        return Pool.whoisLogin(output.stdout)
    }

    private func find() async -> String? {
        if let path { return path }
        for candidate in Self.candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            if await Self.run(candidate, ["version"])?.status == 0 { path = candidate; return candidate }
        }
        if let found = await Self.run("/bin/zsh", ["-lc", "command -v tailscale"]), found.status == 0,
           let line = String(data: found.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), line.hasPrefix("/") {
            path = line
            return line
        }
        return nil
    }

    /// Arguments as an array, never through a shell (but for the PATH lookup); ten seconds at most.
    static func run(_ path: String, _ arguments: [String]) async -> (status: Int32, stdout: Data)? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            let box = Once(continuation)
            do { try process.run() } catch { box.resume(nil); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if process.isRunning { process.terminate() } }
            // Read to the end before waiting: a status larger than the pipe's buffer would otherwise never exit.
            DispatchQueue.global().async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                box.resume(process.terminationReason == .uncaughtSignal ? nil : (process.terminationStatus, data))
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private var continuation: CheckedContinuation<(status: Int32, stdout: Data)?, Never>?
        private let lock = NSLock()
        init(_ continuation: CheckedContinuation<(status: Int32, stdout: Data)?, Never>) { self.continuation = continuation }
        func resume(_ value: (status: Int32, stdout: Data)?) {
            lock.lock(); defer { lock.unlock() }
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}

/// The application firewall's verdict on this copy of Side A. Read only; Side A never changes firewall rules.
enum Firewall {
    static let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"
    static let settings = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")!

    static func status() async -> FirewallStatus? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else { return nil }
        func ask(_ flag: String) async -> String? {
            await TailscaleCLI.run(tool, [flag]).flatMap { String(data: $0.stdout, encoding: .utf8) }
        }
        guard let global = await ask("--getglobalstate") else { return nil }
        if !global.contains("State = 1"), !global.contains("State = 2") { return .off }
        guard let blockAll = await ask("--getblockall"), let allowSigned = await ask("--getallowsigned"),
              let listing = await ask("--listapps") else { return nil }
        return FirewallStatus.parse(global: global, blockAll: blockAll, allowSigned: allowSigned, listing: listing, executable: executable,
                                    signed: KeepAwakeHelper.teamID() != nil)
    }
}
