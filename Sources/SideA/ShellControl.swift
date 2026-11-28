import AppKit
import Darwin
import Foundation
import SideAProtocol
import SideARemoteKit

/// The `sidea` command's way into the running app: one Unix socket, `runtime/cli/app.sock`, in a folder only this user
/// can open (0700, the socket 0600), with any other peer turned away. A connection carries one request line of at most
/// 1 KiB and gets one reply, then closes. What a request may be, and what an answer holds, is `ShellControl`'s.
final class ShellSocket: @unchecked Sendable {
    typealias Answer = @Sendable (String) async -> String

    static let maxLine = 1024
    /// How long a connection has to say what it wants.
    static let headWithin: TimeInterval = 5
    static let maxOpen = 8

    let path: String
    private let queue = DispatchQueue(label: "com.arnenoori.sidea.shell")
    private let answer: Answer
    private var listener: DispatchSourceRead?
    private var reading: [UInt64: (fd: Int32, source: DispatchSourceRead, line: Data)] = [:]
    private var next: UInt64 = 0

    init(folder: URL, answer: @escaping Answer) throws {
        self.answer = answer
        path = folder.appendingPathComponent("app.sock").path
        try Self.privateFolder(folder)
        let fd = try TerminalRelay.listen(path)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        queue.sync { listener = source }
        source.resume()
    }

    /// The folder, made 0700 when it is new and checked when it is not: a directory of this user's, and not a link.
    static func privateFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), chmod(folder.path, 0o700) == 0 else {
            throw TerminalRelay.Failure("Side A couldn’t make a private folder for the sidea command.")
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for entry in reading.values { entry.source.cancel() }
            reading = [:]
        }
        unlink(path)
    }

    private func accept(_ listener: Int32) {
        while true {
            let fd = TerminalRelay.next(listener)
            guard fd >= 0 else { return }
            guard reading.count < Self.maxOpen else {
                Darwin.close(fd)
                continue
            }
            next += 1
            let id = next
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(id) }
            source.setCancelHandler { Darwin.close(fd) }
            reading[id] = (fd, source, Data())
            source.resume()
            queue.asyncAfter(deadline: .now() + Self.headWithin) { [weak self] in self?.drop(id) }
        }
    }

    private func read(_ id: UInt64) {
        guard var entry = reading[id] else { return }
        var chunk = [UInt8](repeating: 0, count: 512)
        let count = Darwin.read(entry.fd, &chunk, chunk.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0 else { return drop(id) }
        entry.line.append(contentsOf: chunk[..<count])
        let end = entry.line.firstIndex(of: 10)
        guard end != nil || entry.line.count > Self.maxLine else {
            reading[id] = entry
            return
        }
        // Its own descriptor for the reply: the read source closes the one it watched when it is cancelled.
        let out = dup(entry.fd)
        drop(id)
        guard out >= 0 else { return }
        let line = entry.line[..<(end ?? entry.line.endIndex)]
        guard line.count <= Self.maxLine else { return Self.send(ShellControl.no("That request is too long."), to: out) }
        guard let text = String(data: line, encoding: .utf8) else { return Self.send(ShellControl.no("Side A doesn't take that request."), to: out) }
        let answer = answer, queue = queue
        Task {
            let reply = await answer(text)
            queue.async { Self.send(reply, to: out) }
        }
    }

    private func drop(_ id: UInt64) {
        reading.removeValue(forKey: id)?.source.cancel()
    }

    /// Writes the whole reply and closes, giving up on a reader that stops reading.
    private static func send(_ reply: String, to fd: Int32) {
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var wait = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let bytes = Array((reply.hasSuffix("\n") ? reply : reply + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 { offset += written } else if written < 0, errno == EINTR { continue } else { return }
        }
    }
}

/// What the `sidea` command may ask the running app, and nothing else: `attach NAME@COMPUTER` makes the sockets for a
/// terminal on that linked computer's session, as a tab here gets them, and answers with their folder; `list` answers
/// with every live hosted session on the linked computers as `NAME@COMPUTER  AGENT  FOLDER`. A reply is "ok" with
/// those lines, or "no" and one sentence. Tokens, keys and logins stay in the app.
@MainActor
final class ShellControl {
    let root: URL
    private let computers: @MainActor () -> [LinkedComputer]
    private let peer: @MainActor (LinkedComputer) -> RemotePeer?
    /// The colours the session there is told the terminal has.
    var theme: @MainActor () -> TermTheme? = { nil }
    private var socket: ShellSocket?

    init(root: URL, computers: @escaping @MainActor () -> [LinkedComputer], peer: @escaping @MainActor (LinkedComputer) -> RemotePeer?) {
        self.root = root; self.computers = computers; self.peer = peer
    }

    static func folder(_ root: URL) -> URL { root.appendingPathComponent("runtime/cli") }

    func start() throws {
        guard socket == nil else { return }
        socket = try ShellSocket(folder: Self.folder(root)) { [weak self] line in
            await self?.answer(line) ?? ShellControl.no("Side A is quitting.")
        }
    }

    func stop() {
        socket?.stop()
        socket = nil
    }

    /// One line of the reply, so a sentence never spills into the next.
    nonisolated static func no(_ sentence: String) -> String {
        "no " + String(sentence.map { $0.isNewline || $0 == "\t" ? " " : $0 })
    }

    func answer(_ line: String) async -> String {
        if line == "list" { return await list() }
        if line.hasPrefix("attach ") { return await attach(String(line.dropFirst("attach ".count))) }
        return Self.no("Side A doesn't take that request.")
    }

    /// The linked computer `name` names, by its name or its id, in any case.
    func computer(_ name: String) -> Result<LinkedComputer, ShellRefusal> {
        let matches = computers().filter { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.caseInsensitiveCompare(name) == .orderedSame }
        guard let first = matches.first else { return .failure(ShellRefusal("No linked computer is called \(name).")) }
        guard matches.count == 1 else {
            return .failure(ShellRefusal("\(matches.count) linked computers are called \(name). Name one by its id: \(matches.map(\.id).joined(separator: ", "))."))
        }
        return .success(first)
    }

    func attach(_ target: String) async -> String {
        // Side A's session names have no @, so the first one ends the name and the rest is the computer.
        guard let at = target.firstIndex(of: "@"), at != target.startIndex, target.index(after: at) != target.endIndex else {
            return Self.no("Name a session on a linked computer: sidea attach <session>@<computer>.")
        }
        let name = String(target[..<at])
        let computer: LinkedComputer
        switch self.computer(String(target[target.index(after: at)...])) {
        case .success(let found): computer = found
        case .failure(let refusal): return Self.no(refusal.sentence)
        }
        guard computer.hostsTerminals else { return Self.no("\(computer.name) can’t open its sessions in a terminal here yet.") }
        guard let peer = peer(computer) else { return Self.no("\(computer.name) isn’t linked any more.") }
        let running: [HostedSession]
        do { running = try await peer.hosted() } catch { return Self.no(peer.sentence(error)) }
        guard let session = running.first(where: { $0.alive && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return Self.no("No session called \(name) is running on \(computer.name). sidea ls --all lists them.")
        }
        do {
            return "ok " + (try LinkedTerminals.start(session.name, peer: peer, root: root, theme: theme())).folder.path
        } catch {
            return Self.no(error.localizedDescription)
        }
    }

    func list() async -> String {
        let peers = computers().filter(\.hostsTerminals).compactMap { computer in peer(computer).map { (computer, $0) } }
        let lines = await withTaskGroup(of: (Int, [String]).self) { group in
            for (index, (computer, peer)) in peers.enumerated() {
                group.addTask {
                    do {
                        let running = try await peer.hosted().filter(\.alive).sorted { $0.createdAt > $1.createdAt }
                        return (index, running.map { "\($0.name)@\(computer.name)  \($0.agent.rawValue)  \($0.cwd)" })
                    } catch {
                        return (index, ["! " + peer.sentence(error)])
                    }
                }
            }
            var lists = [[String]](repeating: [], count: peers.count)
            for await (index, list) in group { lists[index] = list }
            return lists.flatMap { $0 }
        }
        return (["ok"] + lines.map { String($0.map { $0.isNewline ? " " : $0 }) }).joined(separator: "\n")
    }
}

struct ShellRefusal: Error {
    let sentence: String
    init(_ sentence: String) { self.sentence = sentence }
}

extension ShellControl {
    private static var running: ShellControl?

    /// Starts answering the `sidea` command for this run of the app. Without it the command says Side A isn't running.
    static func begin(_ store: AccountStore) {
        guard running == nil else { return }
        let control = forApp(store)
        do {
            try control.start()
            running = control
        } catch {
            RemoteLog.shared("sidea: the command's socket couldn't be opened: \(error.localizedDescription)")
        }
    }

    /// The app's own: its root, its linked computers, and the tab's light or dark.
    static func forApp(_ store: AccountStore) -> ShellControl {
        let control = ShellControl(root: store.root, computers: { [weak store] in store?.remote.computers.all ?? [] },
                                   peer: { [weak store] computer in store.flatMap { $0.remote.computers.peer(computer.id, me: $0.remote.mac) } })
        control.theme = {
            let dark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return TermTheme(appearance: dark ? .dark : .light)
        }
        return control
    }
}
