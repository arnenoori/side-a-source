import Foundation

/// A blocking client for the control socket: one JSON object per line each way.
public final class ControlClient {
    private let handle: FileHandle
    private var buffer = Data()

    public init(path: String) throws {
        #if os(Linux)
        let stream = Int32(SOCK_STREAM.rawValue)
        #else
        let stream = SOCK_STREAM
        #endif
        let descriptor = socket(AF_UNIX, stream, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(descriptor); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in for (index, byte) in bytes.enumerated() { raw[index] = UInt8(bitPattern: byte) } }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { let reason = errno; close(descriptor); throw POSIXError(POSIXErrorCode(rawValue: reason) ?? .ECONNREFUSED) }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    public func send(_ object: [String: Any]) {
        handle.write(Data(ControlWire.line(object).utf8))
    }

    /// The next line, or nil when the daemon closed the socket.
    public func receive() -> [String: Any]? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[(newline + 1)...])
                if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { return object }
                continue
            }
            let chunk = handle.nextChunk()
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }
}

/// `sidead run | pair | accounts | status | devices | revoke | version`.
public enum DaemonCLI {
    static let usage = """
        usage: sidead [run] [--state-dir DIR] [--port N] [--listen ADDRESS]... [--lan] [--allow-host NAME]... [--no-discover] [--name NAME] [--project DIR]... [--landing DIR] [--relay URL | --no-relay] [--no-tunnel]
               sidead pair [--state-dir DIR]       show a code and QR for the iPhone (or for a Mac linking to this computer), then confirm the comparison digits
               sidead accounts [add NAME | adopt NAME [--dir DIR] | remove NAME]   Claude accounts and their limits
               sidead hooks [on | off | status]   send Claude Code's permission requests to the phone (edits Claude Code's settings.json)
               sidead computers | unlink COMPUTER   the computers linked to this one, which sessions can move to and from
               sidead move SESSION COMPUTER       send a hosted, idle session to a linked computer
               sidead move --all COMPUTER         send every hosted, idle session there, one at a time
               sidead moves | move --run-here MOVE [--yes]   the moves this computer sent; start one whose outcome is unknown here again
               sidead config [accept-sessions on|off | include-env on|off | standby COMPUTER|off]   moves and standby
               sidead status | devices | revoke ID | version
        """

    struct Options {
        var command = "run"
        var rest: [String] = []
        var stateDir: String?
        var config: DaemonConfig?
        var port: Int?
        var listen: [String] = []
        var lan = false
        var allowedHosts: [String] = []
        var discover = true
        var name: String?
        var projects: [String] = []
        var selector: AccountSelector?
        var relay: String?
        var noTunnel = false
        var noRelay = false
        var dir: String?
        var landing: String?
        var all = false
        var runHere = false
        var yes = false
    }

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var queue = arguments[...]
        if let first = queue.first, !first.hasPrefix("-") { options.command = first; queue.removeFirst() }
        while let flag = queue.popFirst() {
            switch flag {
            case "--state-dir": options.stateDir = queue.popFirst()
            case "--port": options.port = queue.popFirst().flatMap { Int($0) }
            case "--listen", "--host": if let value = queue.popFirst() { options.listen.append(value) }
            case "--lan": options.lan = true
            case "--allow-host": if let value = queue.popFirst() { options.allowedHosts.append(value) }
            case "--no-discover": options.discover = false
            case "--name": options.name = queue.popFirst()
            case "--project": if let value = queue.popFirst() { options.projects.append(value) }
            case "--dir": options.dir = queue.popFirst()
            case "--landing": options.landing = queue.popFirst()
            case "--relay": options.relay = queue.popFirst()
            case "--no-tunnel": options.noTunnel = true
            case "--no-relay": options.noRelay = true
            case "--account-selector":
                guard let value = queue.popFirst(), let selector = AccountSelector(option: value) else { return nil }
                options.selector = selector
            case "--all": options.all = true
            case "--run-here": options.runHere = true
            case "--yes", "-y": options.yes = true
            case "--version": options.command = "version"
            case "--help", "-h": options.command = "help"
            default:
                if flag.hasPrefix("-") { return nil }
                options.rest.append(flag)
            }
        }
        return options
    }

    public static func main(_ arguments: [String]) async -> Int32 {
        guard let options = parse(arguments) else { return fail(usage, 2) }
        let paths = DaemonPaths.resolve(override: options.stateDir)
        switch options.command {
        case "version": return out("sidead \(SideADaemon.version)")
        case "help": return out(usage)
        case "run": return await run(options, paths)
        case "pair": return pair(paths)
        case "accounts": return await accounts(options, paths)
        case "status": return status(paths)
        case "devices": return devices(paths)
        case "revoke": return revoke(paths, options.rest.first)
        case "hooks": return await hooks(options, paths)
        case "computers": return computers(paths)
        case "unlink": return unlink(paths, options.rest.first)
        case "move": return move(paths, options)
        case "moves": return moves(paths)
        case "config": return await config(paths, options.rest)
        default: return fail(usage, 2)
        }
    }

    @discardableResult
    static func out(_ text: String) -> Int32 { FileHandle.standardOutput.write(Data((text + "\n").utf8)); return 0 }

    static func fail(_ text: String, _ code: Int32 = 1) -> Int32 { FileHandle.standardError.write(Data((text + "\n").utf8)); return code }

    // MARK: run

    static func run(_ options: Options, _ paths: DaemonPaths) async -> Int32 {
        var config = DaemonConfig(paths: paths)
        config.listen = options.listen
        config.lan = options.lan
        config.allowedHosts = options.allowedHosts
        config.discover = options.discover
        if let port = options.port { config.port = port }
        if let name = options.name { config.name = name }
        switch RelayChoice.resolve(option: options.relay, disabled: options.noRelay, environment: ProcessInfo.processInfo.environment) {
        case .off: break
        case .invalid(let text): return fail("sidead: \(text) isn't a relay address.", 2)
        case .use(let url):
            var relay = RelayConfig(url: url)
            relay.tunnel = !options.noTunnel
            config.relay = relay
        }
        do {
            let daemon = try SideADaemon(config: config, services: services(options, paths))
            try await daemon.start()
            let control = try await ControlServer.start(daemon: daemon, path: paths.socket.path)
            let paired = await daemon.devices.devices.count
            out("sidead \(config.version) listening on https://\(config.listen.first ?? "127.0.0.1"):\(daemon.port) key \(daemon.identity.keyID) fp \(daemon.identity.spkiHash)")
            out(paired == 0 ? "No iPhone is paired. Run `sidead pair` to pair one." : "\(paired) iPhone\(paired == 1 ? "" : "s") paired.")
            await withTaskCancellationHandler {
                await Signals.untilTerminated()
            } onCancel: {}
            try await control.stop()
            try await daemon.stop()
            return 0
        } catch {
            return fail("sidead: \(error)")
        }
    }

    /// Accounts always; sessions when the Python bridge is there. Without a python3 and the bridge scripts the daemon still
    /// pairs and stays connected.
    static func services(_ options: Options, _ paths: DaemonPaths) -> any DaemonServices {
        let environment = ProcessInfo.processInfo.environment
        let selector = options.selector ?? environment["SIDEAD_ACCOUNT_SELECTOR"].flatMap { AccountSelector(option: $0) } ?? .configDir
        var reader = UsageReader()
        if let url = environment["SIDEAD_USAGE_URL"].flatMap({ URL(string: $0) }) { reader = UsageReader(url: url) }
        let accounts = AccountsService(book: AccountBook(state: paths.state), selector: selector, reader: reader)
        var projects = options.projects + (environment["SIDEAD_PROJECTS"]?.split(separator: ":").map(String.init) ?? [])
        if projects.isEmpty { projects = [FileManager.default.homeDirectoryForCurrentUser.path] }
        var settings = SessionServices.Settings(root: paths.state.appendingPathComponent("root"), projects: projects)
        if let claude = environment["SIDEAD_CLAUDE"] { settings.agents[.claude] = claude }
        if let codex = environment["SIDEAD_CODEX"] { settings.agents[.codex] = codex }
        settings.accountEnvironment = { await accounts.environment(for: $0) }
        settings.environment["SIDEAD_CLAUDE_DIRS_FILE"] = AccountBook(state: paths.state).foldersFile.path
        let hooks = MoveHooks()
        settings.moves = hooks
        let book = AccountBook(state: paths.state)
        let approvals = Approvals(settings: Approvals.Settings(socket: Hooks.socket(root: settings.root), accountName: { slot in
            slot.flatMap { slot in book.load().first { URL(fileURLWithPath: $0.configDir).lastPathComponent == slot }?.name }
        }))
        let location = BridgeLocation.find()
        guard let location, let sessions = SessionServices(settings: settings, location: location, approvals: approvals) else {
            _ = fail("sidead: python3 or the bridge scripts weren't found, so sessions are off. Set SIDEAD_PYTHON and SIDEAD_BRIDGE.", 0)
            return AccountServices(accounts: accounts)
        }
        let landing = (options.landing ?? environment["SIDEAD_LANDING"]).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Side A")
        let moves = MoveServices(state: paths.state, sessions: sessions, book: book, selector: selector, landing: landing, repositories: projects,
                                 location: location, hooks: hooks)
        return CombinedServices([sessions, moves, ApprovalServices(approvals: approvals), AccountServices(accounts: accounts)])
    }

    // MARK: hooks

    static func hooks(_ options: Options, _ paths: DaemonPaths) async -> Int32 {
        let state = options.rest.first ?? "status"
        guard ["on", "off", "status"].contains(state) else { return fail("usage: sidead hooks [on | off | status]", 2) }
        let result = await Hooks(paths: paths).command(state, location: BridgeLocation.find())
        for line in result.lines {
            if line.hasPrefix("sidead:") { _ = fail(line) } else { out(line) }
        }
        return result.code
    }

    // MARK: accounts

    static func accounts(_ options: Options, _ paths: DaemonPaths) async -> Int32 {
        let book = AccountBook(state: paths.state)
        let environment = ProcessInfo.processInfo.environment
        let selector = options.selector ?? environment["SIDEAD_ACCOUNT_SELECTOR"].flatMap { AccountSelector(option: $0) } ?? .configDir
        do {
            switch options.rest.first {
            case "add":
                guard let name = options.rest.dropFirst().first else { return fail("usage: sidead accounts add NAME") }
                let account = try book.add(name)
                out("Added \(account.name). Sign in to it, once, with:\n\n  \(selector.variable)='\(account.configDir)' claude auth login\n")
                return 0
            case "adopt":
                guard let name = options.rest.dropFirst().first else { return fail("usage: sidead accounts adopt NAME [--dir DIR]") }
                let account = try book.adopt(name, directory: options.dir)
                return out("Added \(account.name), using the login in \(account.configDir).")
            case "remove":
                guard let name = options.rest.dropFirst().first else { return fail("usage: sidead accounts remove NAME") }
                try book.remove(name)
                return out("Removed \(name) from the list. Its folder and login are untouched.")
            case nil, "list":
                var reader = UsageReader()
                if let url = environment["SIDEAD_USAGE_URL"].flatMap({ URL(string: $0) }) { reader = UsageReader(url: url) }
                let list = await AccountsService(book: book, selector: selector, reader: reader).list(refresh: true)
                if list.isEmpty { return out("No accounts. Add one with `sidead accounts add NAME`, or `sidead accounts adopt NAME` for the login already on this computer.") }
                let now = Date().timeIntervalSince1970
                for account in list {
                    let state = account.issue.map { $0.kind == .signedOut ? "not signed in" : $0.kind == .signIn ? "sign in again" : "limits unavailable" } ?? "ready"
                    out("\(account.name)  \(account.email.isEmpty ? "-" : account.email)  \(state)")
                    for window in (account.usage?.windows ?? []) {
                        let reset = window.resetsAt.map { "  resets in \(Self.duration($0 - now))" } ?? ""
                        out("    \(window.label)  \(window.text(at: now))\(reset)\(account.usage?.stale == true ? "  (old reading)" : "")")
                    }
                }
                return 0
            default:
                return fail(usage, 2)
            }
        } catch {
            return fail("sidead: \(error)")
        }
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int(max(seconds, 0) / 60)
        return minutes >= 1_440 ? "\(minutes / 1_440) d \(minutes % 1_440 / 60) h" : minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    // MARK: pair

    static func pair(_ paths: DaemonPaths) -> Int32 {
        guard let client = try? ControlClient(path: paths.socket.path) else {
            return fail("sidead isn't running. Start it first with `sidead run`, or `systemctl --user start sidead`.")
        }
        client.send(["cmd": "pair"])
        while let event = client.receive() {
            switch event["event"] as? String {
            case "code":
                let link = event["link"] as? String ?? ""
                out("\nScan this with the Side A Remote app on your iPhone (Camera, or Side A Remote > Pair):\n")
                if let qr = try? QRCode(text: link) { FileHandle.standardOutput.write(Data(qr.terminal().utf8)) }
                out("\nCode  \(event["code"] as? String ?? "")\nLink  \(link)\n\nWaiting for the iPhone. This code lasts five minutes.")
            case "confirm":
                let name = event["device"] as? String ?? "An iPhone"
                let keyMatches = event["keyMatches"] as? Bool ?? false
                out("\n\(name) wants to pair.\nCheck that its screen shows  \(event["comparison"] as? String ?? "")")
                if !keyMatches {
                    out("It saw a different security key than this daemon's, so pairing can't continue.")
                    client.send(["cmd": "decide", "decision": "mismatch"])
                    continue
                }
                FileHandle.standardOutput.write(Data("Pair it? [y/N] ".utf8))
                let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                client.send(["cmd": "decide", "decision": answer == "y" || answer == "yes" ? "pair" : answer == "m" ? "mismatch" : "cancel"])
            case "paired":
                return out("\nPaired \(event["device"] as? String ?? "the iPhone").")
            case "stopped":
                return fail("\n\(event["reason"] as? String ?? "Pairing stopped.") Run `sidead pair` to try again.")
            default: continue
            }
        }
        return fail("sidead closed the connection.")
    }

    // MARK: status, devices, revoke

    static func status(_ paths: DaemonPaths) -> Int32 {
        guard let client = try? ControlClient(path: paths.socket.path) else {
            out("sidead is not running (state: \(paths.state.path))")
            return 3
        }
        client.send(["cmd": "status"])
        guard let answer = client.receive(), let status = answer["status"] as? [String: String] else { return fail("No answer from sidead.") }
        out("sidead \(status["version"] ?? "") running on \(status["name"] ?? "") (\(status["os"] ?? ""))")
        out("listening on port \(status["port"] ?? "")  key \(status["key"] ?? "")")
        out("paired iPhones: \(status["devices"] ?? "0")")
        out(status["relay"].map { "relay: \($0)  tunnel: \(status["tunnel"] ?? "")" } ?? "relay: off")
        out("secrets: \(status["secrets"] ?? "")")
        return 0
    }

    static func devices(_ paths: DaemonPaths) -> Int32 {
        guard let client = try? ControlClient(path: paths.socket.path) else { return fail("sidead isn't running.") }
        client.send(["cmd": "devices"])
        guard let answer = client.receive(), let devices = answer["devices"] as? [[String: Any]] else { return fail("No answer from sidead.") }
        if devices.isEmpty { return out("No iPhone is paired.") }
        for device in devices {
            let id = (device["id"] as? String ?? "").prefix(8)
            out("\(id)  \(device["name"] as? String ?? "")  \(device["model"] as? String ?? "")  app \(device["app"] as? String ?? "")")
        }
        return 0
    }

    static func revoke(_ paths: DaemonPaths, _ id: String?) -> Int32 {
        guard let id else { return fail("usage: sidead revoke ID") }
        guard let client = try? ControlClient(path: paths.socket.path) else { return fail("sidead isn't running.") }
        client.send(["cmd": "revoke", "id": id])
        guard let answer = client.receive() else { return fail("No answer from sidead.") }
        if answer["ok"] as? Bool == true { return out("Revoked \(answer["revoked"] as? String ?? "the device").") }
        return fail(answer["error"] as? String ?? "Couldn't revoke it.")
    }
}

/// SIGTERM and SIGINT end `run`, so systemd's stop and Ctrl-C both leave through the same clean exit.
enum Signals {
    static func untilTerminated() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once(continuation)
            var sources: [DispatchSourceSignal] = []
            for number in [SIGTERM, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { once.fire() }
                source.resume()
                sources.append(source)
            }
            once.keep(sources)
        }
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var sources: [DispatchSourceSignal] = []
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func keep(_ sources: [DispatchSourceSignal]) { lock.lock(); self.sources = sources; lock.unlock() }
        func fire() { lock.lock(); let next = continuation; continuation = nil; lock.unlock(); next?.resume() }
    }
}
