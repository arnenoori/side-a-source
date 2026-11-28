import Foundation

/// `sidead computers`, `unlink`, `move`, `moves` and `config`, through the running daemon's control socket.
extension DaemonCLI {
    static func computers(_ paths: DaemonPaths) -> Int32 {
        guard let client = try? ControlClient(path: paths.socket.path) else { return fail("sidead isn't running.") }
        client.send(["cmd": "computers"])
        guard let answer = client.receive(), let list = answer["computers"] as? [[String: Any]] else { return fail("No answer from sidead.") }
        if list.isEmpty {
            return out("No computer is linked. On a Mac, choose Link a Computer in Side A's Remote settings and paste the link `sidead pair` shows.")
        }
        for computer in list {
            let id = (computer["id"] as? String ?? "").prefix(8)
            out("\(id)  \(computer["name"] as? String ?? "")  \(computer["os"] as? String ?? "")  \(computer["address"] as? String ?? "")")
        }
        return 0
    }

    static func unlink(_ paths: DaemonPaths, _ name: String?) -> Int32 {
        guard let name else { return fail("usage: sidead unlink COMPUTER") }
        guard let client = try? ControlClient(path: paths.socket.path) else { return fail("sidead isn't running.") }
        client.send(["cmd": "unlink", "computer": name])
        guard let answer = client.receive() else { return fail("No answer from sidead.") }
        if answer["ok"] as? Bool == true { return out("Unlinked \(answer["unlinked"] as? String ?? name). Sessions can no longer move between the two.") }
        return fail(answer["error"] as? String ?? "Couldn't unlink it.")
    }

    static func move(_ paths: DaemonPaths, _ options: Options) -> Int32 {
        let rest = options.rest
        if options.all { return moveAll(paths, rest) }
        if options.runHere { return runHere(paths, rest, yes: options.yes) }
        guard rest.count == 2 else { return fail("usage: sidead move SESSION COMPUTER   (SESSION: its hosted name, as `sa-app-1a2b`, or its conversation id)") }
        guard let client = try? ControlClient(path: paths.socket.path) else { return fail("sidead isn't running.") }
        client.send(["cmd": "move", "session": rest[0], "computer": rest[1]])
        guard let answer = client.receive() else { return fail("No answer from sidead.") }
        guard answer["ok"] as? Bool == true else { return fail(answer["error"] as? String ?? "It didn't move.") }
        let folder = answer["folder"] as? String ?? ""
        return out("Moved to \(rest[1]): it runs there as \(answer["session"] as? String ?? "a hosted session")\(folder.isEmpty ? "" : ", in \(folder)").")
    }

    /// `sidead move --all COMPUTER`, with the Mac's sentences for what stayed.
    static func moveAll(_ paths: DaemonPaths, _ rest: [String]) -> Int32 {
        guard rest.count == 1 else { return fail("usage: sidead move --all COMPUTER") }
        guard let client = try? ControlClient(path: paths.socket.path) else { return fail("sidead isn't running.") }
        client.send(["cmd": "move-all", "computer": rest[0]])
        guard let answer = client.receive() else { return fail("No answer from sidead.") }
        guard answer["ok"] as? Bool == true else { return fail(answer["error"] as? String ?? "Nothing moved.") }
        let moved = answer["moved"] as? [String] ?? [], stayed = answer["stayed"] as? [[String: String]] ?? []
        if !moved.isEmpty { out(moved.count == 1 ? "Moved \(moved[0]) to \(rest[0])." : "Moved \(moved.count) sessions to \(rest[0]).") }
        guard let first = stayed.first else { return 0 }
        return fail(stayed.count == 1 ? "\(first["title"] ?? "One session") stayed here: \(first["reason"] ?? "")" : "\(stayed.count) sessions stayed here. \(first["reason"] ?? "")")
    }

    /// `sidead moves`: what this computer sent and where each stands.
    static func moves(_ paths: DaemonPaths) -> Int32 {
        guard let client = try? ControlClient(path: paths.socket.path) else { return fail("sidead isn't running.") }
        client.send(["cmd": "moves"])
        guard let answer = client.receive(), let list = answer["moves"] as? [[String: Any]] else { return fail("No answer from sidead.") }
        if list.isEmpty { return out("No session is moving, away or unaccounted for.") }
        for move in list {
            let message = move["message"] as? String ?? ""
            out("\(move["id"] as? String ?? "")  \(move["state"] as? String ?? "")  \(move["computer"] as? String ?? "")  \(move["title"] as? String ?? "")"
                + (message.isEmpty ? "" : "  \(message)"))
        }
        return 0
    }

    /// `sidead move --run-here MOVE`: asks first, as the Mac does, unless `--yes`.
    static func runHere(_ paths: DaemonPaths, _ rest: [String], yes: Bool) -> Int32 {
        guard rest.count == 1 else { return fail("usage: sidead move --run-here MOVE [--yes]   (MOVE: its id, as `sidead moves` lists it)") }
        guard let client = try? ControlClient(path: paths.socket.path) else { return fail("sidead isn't running.") }
        client.send(["cmd": "moves"])
        let list = client.receive()?["moves"] as? [[String: Any]] ?? []
        let matching = list.filter { ($0["id"] as? String ?? "").hasPrefix(rest[0]) }
        guard let found = matching.first(where: { $0["id"] as? String == rest[0] }) ?? (matching.count == 1 ? matching.first : nil),
              let id = found["id"] as? String else {
            return fail(matching.isEmpty ? "This computer sent no move with that id. `sidead moves` lists them." : "More than one move starts with that. Give more of its id.")
        }
        if !yes {
            let computer = found["computer"] as? String ?? "the other computer"
            FileHandle.standardOutput.write(Data("Run it here? If \(computer) did start this session, it will run on both. [y/N] ".utf8))
            let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "yes" else { return out("Nothing was started.") }
        }
        client.send(["cmd": "run-here", "move": id])
        guard let answer = client.receive() else { return fail("No answer from sidead.") }
        guard answer["ok"] as? Bool == true else { return fail(answer["error"] as? String ?? "It didn't start here.") }
        return out("It runs here again.")
    }

    /// `sidead config`: Accept Sessions, Include Ignored .env Files and Standby. Through the daemon when it runs, so a
    /// change of standby is acted on at once; otherwise in its state folder, read when it starts.
    static func config(_ paths: DaemonPaths, _ rest: [String]) async -> Int32 {
        let usage = "usage: sidead config [accept-sessions on|off | include-env on|off | standby COMPUTER|off]"
        guard rest.isEmpty || rest.count == 2 else { return fail(usage, 2) }
        let key = rest.first ?? "", value = rest.count == 2 ? rest[1] : ""
        guard key.isEmpty || MoveSettings.keys.contains(key) else { return fail(usage, 2) }
        var lines: [[String: String]]
        if let client = try? ControlClient(path: paths.socket.path) {
            client.send(["cmd": "config", "key": key, "value": value])
            guard let answer = client.receive() else { return fail("No answer from sidead.") }
            guard answer["ok"] as? Bool == true, let shown = answer["settings"] as? [[String: String]] else { return fail(answer["error"] as? String ?? "Nothing changed.") }
            lines = shown
        } else {
            let store = FileSecretStore(directory: paths.state)
            let computers = await ComputerLinks(store: store).all
            var settings = MoveSettings.load(store)
            if !key.isEmpty {
                do {
                    settings = try settings.changed(key, to: value, computers: computers)
                    try MoveSettings.save(settings, to: store)
                } catch { return fail(DaemonMoves.sentence(error, peer: nil)) }
            }
            lines = settings.lines(computers: computers)
        }
        for line in lines { out("\(line["key"] ?? "")  \(line["value"] ?? "")") }
        return 0
    }
}
