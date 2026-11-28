import Darwin
import Foundation
import SideACore
import SideAProtocol
import SideARemoteKit

/// The tab's end of a terminal on another computer: a private folder with two Unix sockets the app listens on. `tty`
/// carries the tab's bytes both ways and takes one connection, the tab's; each connection to `size` is one
/// "cols rows" line. Only this user reaches them: the folder is 0700, the sockets 0600, and any other peer is turned
/// away. Everything here runs on the relay's own queue.
final class TerminalRelay: @unchecked Sendable {
    enum Event: Sendable, Equatable {
        case connected
        case input(Data)
        case size(cols: Int, rows: Int)
        /// The tab closed or went quiet for good, or `finish` ran. Nothing follows.
        case closed
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Output a tab that stopped reading may hold back before it is let go.
    static let maxPending = 8 << 20

    let folder: URL
    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let queue = DispatchQueue(label: "com.arnenoori.sidea.relay")
    private var listeners: [DispatchSourceRead] = []
    private var tab: Int32 = -1
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var sizers: [Int32: (source: DispatchSourceRead, line: Data)] = [:]
    private var pending = Data()
    private var closing = false
    private var done = false

    var ttyPath: String { folder.appendingPathComponent("tty").path }
    var sizePath: String { folder.appendingPathComponent("size").path }

    init(folder: URL) throws {
        self.folder = folder
        (events, continuation) = AsyncStream.makeStream()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let tty = try Self.listen(ttyPath)
            let size: Int32
            do { size = try Self.listen(sizePath) } catch { Darwin.close(tty); throw error }
            queue.sync {
                listeners = [watch(tty) { [weak self] in self?.acceptTab(tty) }, watch(size) { [weak self] in self?.acceptSize(size) }]
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Queues `data` for the tab.
    func write(_ data: Data) {
        queue.async { [self] in
            guard !closing, tab >= 0 else { return }
            pending += data
            guard pending.count <= Self.maxPending else { return close() }
            pump()
        }
    }

    /// Says `trailer` to the tab when one is there, then closes both sockets and removes the folder.
    func finish(_ trailer: Data? = nil) {
        queue.async { [self] in
            guard !closing else { return }
            closing = true
            if let trailer, tab >= 0 { pending += trailer }
            guard tab >= 0, !pending.isEmpty else { return close() }
            pump()
            // A tab that stopped reading doesn't keep the relay open.
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.close() }
        }
    }

    static func listen(_ path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure("Side A’s folder is too deep for a terminal socket (\(bytes.count) bytes).")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("Side A couldn’t open a terminal socket.") }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 4) == 0 else {
            Darwin.close(fd)
            unlink(path)
            throw Failure("Side A couldn’t listen for the terminal tab.")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    /// "120 40" as the wrapper sends it; nil for anything else.
    static func size(_ line: Data) -> (cols: Int, rows: Int)? {
        let words = String(decoding: line.prefix { $0 != 10 }, as: UTF8.self).split(separator: " ")
        guard words.count == 2, let cols = Int(words[0]), let rows = Int(words[1]), cols > 0, rows > 0 else { return nil }
        return (cols, rows)
    }

    private func watch(_ listener: Int32, _ handler: @escaping @Sendable () -> Void) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { Darwin.close(listener) }
        source.resume()
        return source
    }

    /// The next connection from this user, non-blocking; -1 when none is waiting.
    static func next(_ listener: Int32) -> Int32 {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return -1 }
            var uid = uid_t(0), gid = gid_t(0)
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                Darwin.close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            return fd
        }
    }

    private func acceptTab(_ listener: Int32) {
        while true {
            let fd = Self.next(listener)
            guard fd >= 0 else { return }
            guard tab < 0, !closing else {
                Darwin.close(fd)
                continue
            }
            tab = fd
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in self?.read() }
            reader.setCancelHandler { Darwin.close(fd) }
            reader.resume()
            self.reader = reader
            // One tab per folder: nobody else can join it now.
            listeners.first?.cancel()
            unlink(ttyPath)
            continuation.yield(.connected)
        }
    }

    private func read() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(tab, &chunk, chunk.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0 else { return close() }
        continuation.yield(.input(Data(chunk[..<count])))
    }

    private func acceptSize(_ listener: Int32) {
        while true {
            let fd = Self.next(listener)
            guard fd >= 0 else { return }
            guard sizers.count < 8, !closing else {
                Darwin.close(fd)
                continue
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readSize(fd) }
            source.setCancelHandler { Darwin.close(fd) }
            sizers[fd] = (source, Data())
            source.resume()
        }
    }

    private func readSize(_ fd: Int32) {
        guard var entry = sizers[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(fd, &chunk, chunk.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        if count > 0 { entry.line.append(contentsOf: chunk[..<count]) }
        sizers[fd] = entry
        guard count <= 0 || entry.line.contains(10) || entry.line.count > 64 else { return }
        sizers[fd] = nil
        // Closing answers the wrapper, which waits for it before it connects the tab.
        entry.source.cancel()
        if let size = Self.size(entry.line) { continuation.yield(.size(cols: size.cols, rows: size.rows)) }
    }

    private func pump() {
        while tab >= 0, !pending.isEmpty {
            let count = pending.withUnsafeBytes { Darwin.write(tab, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { return wait() }
            guard count > 0 else { return close() }
            pending.removeFirst(count)
        }
        if closing { close() }
    }

    private func wait() {
        guard writer == nil, tab >= 0 else { return }
        let writer = DispatchSource.makeWriteSource(fileDescriptor: tab, queue: queue)
        writer.setEventHandler { [weak self] in
            guard let self else { return }
            self.writer?.cancel()
            self.writer = nil
            pump()
        }
        writer.resume()
        self.writer = writer
    }

    private func close() {
        guard !done else { return }
        done = true
        closing = true
        writer?.cancel()
        writer = nil
        // Its cancel handler closes the tab's socket.
        reader?.cancel()
        reader = nil
        tab = -1
        listeners.forEach { $0.cancel() }
        listeners = []
        sizers.values.forEach { $0.source.cancel() }
        sizers = [:]
        pending = Data()
        try? FileManager.default.removeItem(at: folder)
        continuation.yield(.closed)
        continuation.finish()
    }
}

/// A tab here on a hosted session of a linked computer: what the tab types goes to the other computer's terminal
/// stream and what the session draws comes back. Closing the tab only detaches; the session goes on there.
actor LinkedTerminal {
    private enum Part { case tab, stream, clock }

    /// How long a tab has to connect after the folder is made.
    static let patience: Duration = .seconds(60)
    /// Reconnects in a row before the tab is told the link is lost.
    static let retries = 3

    let name: String
    private let peer: RemotePeer
    private let relay: TerminalRelay
    private let session: TerminalSession
    private let theme: TermTheme?
    private var size = (cols: 80, rows: 24)
    private var connected = false
    private var ready = false
    private var flushing = false
    private var ending = false
    private var exited = false
    private var tries = 0
    private var pending = Data()

    init(_ name: String, peer: RemotePeer, relay: TerminalRelay, session: TerminalSession, theme: TermTheme?) {
        self.name = name; self.peer = peer; self.relay = relay; self.session = session; self.theme = theme
    }

    /// Runs until the tab closes or the session ends there.
    func run(patience: Duration = LinkedTerminal.patience) async {
        let relay = relay, session = session
        await withTaskGroup(of: Part.self) { group in
            group.addTask {
                for await event in relay.events { await self.relayed(event) }
                return .tab
            }
            group.addTask {
                for await event in session.events { await self.heard(event) }
                return .stream
            }
            group.addTask {
                do { try await Task.sleep(for: patience) } catch { return .clock }
                await self.expire()
                return .clock
            }
            while let part = await group.next(), part != .tab {}
            group.cancelAll()
        }
        ending = true
        await session.close()
    }

    private func relayed(_ event: TerminalRelay.Event) async {
        switch event {
        case .size(let cols, let rows):
            size = (cols, rows)
            if ready { await session.resize(cols: cols, rows: rows) }
        case .connected:
            connected = true
            await connect()
        case .input(let bytes):
            pending += bytes
            await flush()
        case .closed:
            ending = true
        }
    }

    private func heard(_ event: TerminalSession.Event) async {
        switch event {
        case .output(let bytes): relay.write(bytes)
        case .size:
            // The first size after an open is its `ready`: keys can go now.
            if !ready { ready = true; tries = 0 }
            await flush()
        case .drained: await flush()
        case .notice(let text): relay.write(Data("\r\n[\(text)]\r\n".utf8))
        case .exit: exited = true
        case .closed(let code):
            ready = false
            await closed(code)
        case .copyMode: break
        }
    }

    private func connect() async {
        guard !ending else { return }
        do {
            try await session.open(cols: size.cols, rows: size.rows, theme: theme)
        } catch {
            await closed((error as? SocketClosed)?.code ?? 1006)
        }
    }

    /// In order, at most 64 KiB at a time, and only once the other computer is ready for this socket's keys.
    private func flush() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        while ready, !ending, !pending.isEmpty {
            let part = pending.prefix(64 * 1024)
            guard await session.input(Data(part)) else { return }
            pending.removeFirst(part.count)
        }
    }

    /// The session's end needs no word: tmux has already put the tab back and said so.
    private func closed(_ code: Int) async {
        guard !ending else { return }
        guard !exited, code != 4410 else { return end(nil) }
        guard Self.settled.contains(code) || tries >= Self.retries else {
            tries += 1
            if tries == 1 { relay.write(Data("\r\n[Reaching \(peer.name)…]\r\n".utf8)) }
            do { try await Task.sleep(for: .milliseconds(500 * tries)) } catch { return }
            return await connect()
        }
        let message = Self.settled.contains(code) ? Self.farewell(code, computer: peer.name) : await lost()
        end(Self.trailer(message))
    }

    /// Why a terminal that kept failing did, asked of the routes, which say more than a refused upgrade does.
    private func lost() async -> String {
        do {
            let running = try await peer.hosted().contains { $0.name == name && $0.alive }
            return running ? "\(peer.name) didn’t open its terminal for this Mac. Link it again in Remote settings."
                : "That session isn’t running on \(peer.name) any more."
        } catch {
            return peer.sentence(error)
        }
    }

    private func expire() {
        guard !connected else { return }
        end(nil)
    }

    private func end(_ trailer: Data?) {
        guard !ending else { return }
        ending = true
        relay.finish(trailer)
    }

    /// Closes that another try can't change.
    static let settled: Set<Int> = [1000, 4401, 4403, 4404, 4409, 4410, 4426]

    static func farewell(_ code: Int, computer: String) -> String {
        switch code {
        case 4401, 4403: "\(computer) didn’t open its terminal for this Mac. Link it again in Remote settings."
        case 4404: "That session isn’t running on \(computer) any more."
        case 4409: "Too many terminals are open on that session."
        default: "Lost the connection to \(computer)."
        }
    }

    /// Back to the tab's own screen with the modes a session turns on switched off, then one line saying why.
    static func trailer(_ message: String) -> Data {
        Data(("\u{1B}[?1049l\u{1B}[?25h\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?2004l\u{1B}[?1004l\r\n[" + message + "]\r\n").utf8)
    }
}

/// The tabs open on other computers' sessions, and the wrapper each one runs.
@MainActor
enum LinkedTerminals {
    struct Opened {
        /// What the tab runs: the wrapper with the folder.
        let command: String
        let folder: URL
    }

    private(set) static var running: [String: LinkedTerminal] = [:]
    private static var swept: Set<String> = []

    static func wrapper(_ root: URL) -> URL { root.appendingPathComponent("runtime/sidea-remote") }

    /// Makes the sockets for one tab on `name` and starts listening; the tab has a minute to connect.
    static func start(_ name: String, peer: RemotePeer, root: URL, theme: TermTheme? = nil, patience: Duration = LinkedTerminal.patience) throws -> Opened {
        guard name.hasPrefix("sa-"), IDs.safe(name) else { throw TerminalRelay.Failure("That isn’t a session Side A can open.") }
        // No key, no terminal: say so here rather than in a tab that never fills.
        _ = try peer.signature(.terminal, subject: ConfirmMessage.subject(terminal: name), faceID: true)
        let folders = root.appendingPathComponent("runtime/rt")
        // Folders a crash or a quit left behind; one per app run is enough.
        if swept.insert(folders.path).inserted { sweep(folders) }
        try install(wrapper(root))
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let relay = try TerminalRelay(folder: folders.appendingPathComponent(id))
        let outbox: Outbox
        do {
            outbox = try Outbox(file: relay.folder.appendingPathComponent("input.sqlite"))
        } catch {
            relay.finish()
            throw error
        }
        let terminal = LinkedTerminal(name, peer: peer, relay: relay, session: peer.terminal(name, viewer: UUID().uuidString, outbox: outbox), theme: theme)
        running[id] = terminal
        Task {
            await terminal.run(patience: patience)
            running[id] = nil
        }
        return Opened(command: "\(Shell.quote(wrapper(root).path)) \(Shell.quote(relay.folder.path))", folder: relay.folder)
    }

    private static func sweep(_ folders: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folders.path)) ?? []
        for name in names where running[name] == nil {
            try? FileManager.default.removeItem(at: folders.appendingPathComponent(name))
        }
    }

    /// Written whenever it differs, so the tab always runs this build's.
    static func install(_ url: URL) throws {
        let data = Data(script.utf8)
        if FileManager.default.contents(atPath: url.path) != data { try PrivateFile.write(data: data, to: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// zsh and macOS's own `nc` and `stty`, nothing else. `nc -U` exits when the app closes the socket; a WINCH trap
    /// runs while the shell waits on it, so a resize is a short second connection.
    static let script = #"""
    #!/bin/zsh -f
    # Written by Side A for a terminal tab on another computer's session; edits are overwritten.
    # sidea-remote FOLDER joins this terminal to the session Side A set up in FOLDER until the tab closes, which only
    # detaches, or the session ends. FOLDER holds the app's two sockets: tty (this terminal's bytes, both ways) and size
    # (one "cols rows" line per connection).
    # bg_nice would run the nc that carries the keys at a lower priority.
    emulate -L zsh; setopt no_unset no_bg_nice
    dir=${1:-}
    if (( $# != 1 )) || [[ ! -S $dir/tty || ! -S $dir/size ]]; then
      print -u2 "usage: sidea-remote FOLDER (Side A runs this in the tab it opens)"; exit 64
    fi
    [[ -t 0 && -t 1 ]] || { print -u2 "sidea-remote: not a terminal"; exit 64; }
    nc=/usr/bin/nc pid=0
    report_size() {
      local -a s; s=(${=$(stty size </dev/tty 2>/dev/null)})
      (( $#s == 2 )) && print -r -- "$s[2] $s[1]" | $nc -U -w 2 $dir/size >/dev/null 2>&1
      return 0
    }
    saved=$(stty -g </dev/tty) || exit 69
    trap report_size WINCH
    trap '(( pid )) && kill $pid 2>/dev/null' HUP INT TERM
    report_size
    stty raw -echo </dev/tty
    $nc -U $dir/tty </dev/tty &
    pid=$!
    while kill -0 $pid 2>/dev/null; do wait $pid; done
    stty $saved </dev/tty 2>/dev/null
    # Whatever the session left on: a hidden cursor, mouse reporting, bracketed paste, focus events, extended keys.
    print -n $'\e[?25h\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?2004l\e[?1004l\e[>4m\e[<u'

    """#
}
