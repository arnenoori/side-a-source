import CSideAPTY
import Foundation
import SideACore
import SideAProtocol

/// `/v1/ws/term/{name}` (protocol's terminal section, hosting's Terminal streaming): each phone view gets its own
/// tmux client in a PTY Side A owns. Everything here runs on the server's queue; tmux is asked through
/// `HostedSessions` on the main actor.
final class TerminalHub: @unchecked Sendable {
    static let maxViewers = 4
    /// How long a viewer's `applied` outlives its socket.
    static let remembered: TimeInterval = 120
    static let evaluateEvery: TimeInterval = 5

    let queue: DispatchQueue
    let epoch: String
    private let hosted: @MainActor () -> HostedSessions?
    private var viewers: [UInt64: TerminalViewer] = [:]
    /// By device and viewer id: the last input seq written to the PTY.
    private var records: [String: (seq: UInt32, until: Date)] = [:]
    /// How sessions whose agent just exited ended, read when their viewers' clients go.
    private var endings: [String: (status: Int?, reason: TermExitReason)] = [:]
    /// What each session's window was last set to, so an unchanged decision runs no tmux.
    private var applied: [String: RemoteTerminal.Size] = [:]
    private var evaluating: Set<String> = []
    private var again: Set<String> = []
    private var timer: DispatchSourceTimer?
    /// Tests stand in a slower start for the tmux client.
    var launch: (@Sendable (TerminalViewer.Command) -> TerminalViewer.Command)?

    init(queue: DispatchQueue, epoch: String, hosted: @escaping @MainActor () -> HostedSessions?) {
        self.queue = queue; self.epoch = epoch; self.hosted = hosted
    }

    // MARK: Sockets

    func attach(_ peer: WebSocketPeer, name: String) {
        let viewer = TerminalViewer(peer: peer, name: name, hub: self)
        viewers[peer.id] = viewer
        peer.message = { [weak viewer] message in viewer?.received(message) }
        peer.ending = { [weak self, weak viewer] in
            guard let self, let viewer else { return }
            viewers[peer.id] = nil
            viewer.stop()
            // Cut off part way through a frame: nobody knows how much of it the session got, so the next `ready` says
            // nothing (applied nil) and the phone replays none of it.
            if let key = viewer.recordKey { records[key] = viewer.partial ? nil : (viewer.written, Date().addingTimeInterval(Self.remembered)) }
            if !viewers.values.contains(where: { $0.name == name }) { endings[name] = nil }
            evaluate(name)
        }
        let hosted = hosted, launch = launch
        Task { @MainActor in
            let command = hosted()?.viewer(name).map { launch?($0) ?? $0 }
            self.queue.async { command.map { viewer.resolved($0) } ?? peer.close(4404, "no such session") }
        }
        let others = viewers.values.filter { $0.name == name && $0 !== viewer }.sorted { $0.opened < $1.opened }
        if others.count >= Self.maxViewers { others.first?.peer.close(4409, "too many viewers") }
        startTimer()
    }

    /// Last seq written for this viewer in this epoch, nil without a record.
    func record(_ key: String) -> UInt32? {
        records = records.filter { $0.value.until > Date() }
        return records[key]?.seq
    }

    /// Typing in the phone's terminal: a pending re-press of an earlier reply must not fire.
    func typed(_ name: String) {
        let hosted = hosted
        Task { @MainActor in hosted()?.cancelVerifier(name) }
    }

    func isLatest(_ viewer: TerminalViewer) -> Bool {
        !viewers.values.contains { $0 !== viewer && $0.name == viewer.name && $0.active > viewer.active }
    }

    func ended(_ name: String, status: Int?, reason: TermExitReason) {
        queue.async { [self] in endings[name] = (status, reason) }
    }

    /// The tmux client went away. The session ending is `exit` then 4410 ("lost" when it went without its agent exiting,
    /// such as the tmux server dying); the session still there is a reconnect.
    func clientGone(_ viewer: TerminalViewer) {
        if let ending = endings[viewer.name] {
            return viewer.finish(status: ending.status, reason: ending.reason)
        }
        let name = viewer.name, hosted = hosted
        Task { @MainActor in
            let alive = hosted()?.sessions.contains { $0.name == name } ?? false
            self.queue.async { alive ? viewer.peer.close(1001, "detached") : viewer.finish(status: nil, reason: .lost) }
        }
    }

    // MARK: Size

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.evaluateEvery, repeating: Self.evaluateEvery)
        timer.setEventHandler { [weak self] in self?.evaluateAll() }
        timer.resume()
        self.timer = timer
    }

    /// From the hosted watcher's wakes and the timer.
    func evaluateAll() {
        let names = Set(viewers.values.map(\.name))
        if names.isEmpty { timer?.cancel(); timer = nil }
        for name in names { evaluate(name) }
    }

    /// Decision 5, hosting's Resize. One evaluation per session at a time; a request during one runs it again after.
    func evaluate(_ name: String) {
        guard !evaluating.contains(name) else { again.insert(name); return }
        evaluating.insert(name)
        let phones = viewers.values.filter { $0.name == name && $0.started }
        let wanted = phones.map { RemoteTerminal.Phone(cols: $0.cols, rows: $0.rows, active: $0.active) }
        let last = applied[name], hosted = hosted
        Task { @MainActor in
            guard let hosted = hosted() else { return self.queue.async { self.evaluated(name, nil) } }
            let macs = await hosted.clients(name).filter { !$0.phone }.map(\.activity)
            let size = RemoteTerminal.size(phones: wanted, macActivity: macs, now: Date().timeIntervalSince1970)
            if size != last {
                switch size {
                case .free, .mac: _ = await hosted.command(["set-option", "-w", "-u", "-t", "=\(name):", "window-size"])
                case .phone(let cols, let rows):
                    _ = await hosted.command(["set-option", "-w", "-t", "=\(name):", "window-size", "manual", ";",
                                              "resize-window", "-t", "=\(name):", "-x", String(cols), "-y", String(rows)])
                }
            }
            let shown = await hosted.command(["display-message", "-p", "-t", "=\(name):", "#{window_width}\t#{window_height}\t#{pane_in_mode}"])
            let parts = shown.output.trimmingCharacters(in: .newlines).split(separator: "\t").compactMap { Int($0) }
            let window = shown.status == 0 && parts.count == 3 ? Window(cols: parts[0], rows: parts[1], copy: parts[2] != 0, size: size) : nil
            self.queue.async { self.evaluated(name, window) }
        }
    }

    struct Window { let cols: Int; let rows: Int; let copy: Bool; let size: RemoteTerminal.Size }

    private func evaluated(_ name: String, _ window: Window?) {
        evaluating.remove(name)
        if let window {
            applied[name] = window.size
            for viewer in viewers.values where viewer.name == name { viewer.show(window) }
        }
        if again.remove(name) != nil { evaluate(name) }
    }
}

/// One phone's terminal view: its socket, its tmux client and the client's PTY.
final class TerminalViewer: @unchecked Sendable {
    typealias Command = (path: String, args: [String], environment: [String: String])

    /// Output is held while this much waits on the socket, below the socket's own 1 MiB limit.
    static let pauseAt = 768 * 1024
    static let coalesce: DispatchTimeInterval = .milliseconds(4)
    static let ackEvery: DispatchTimeInterval = .milliseconds(50)
    /// How long tmux's startup queries are answered here.
    static let queryWindow: TimeInterval = 6

    let peer: WebSocketPeer
    let name: String
    let opened = Date()
    private weak var hub: TerminalHub?
    private let queue: DispatchQueue
    private(set) var cols = 80
    private(set) var rows = 24
    private(set) var active: TimeInterval = 0
    private(set) var started = false
    private(set) var recordKey: String?
    /// The last seq whose bytes are all in the PTY.
    private(set) var written: UInt32 = 0
    /// The next frame is partly in the PTY.
    private(set) var partial = false
    private var input = RemoteTerminal.Input()
    private var command: Command?
    private var early: [WebSocketCodec.Message] = []
    private var helloed = false
    private var ready = false
    private var shown: (cols: Int, rows: Int, owner: String)?
    private var copy: Bool?
    private var pid: pid_t = 0
    private var reaped = false
    private var master: Int32 = -1
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var paused = false
    private var buffer = Data()
    private var flushing: DispatchWorkItem?
    private var acking: DispatchWorkItem?
    private var acked: UInt32 = 0
    private var queries = RemoteTerminal.Queries()
    private var queriesUntil = Date.distantFuture
    /// What waits to go into the PTY, in order. Nil bytes is a refused frame, acked with `too_large` when reached; nil seq
    /// is a reply to one of tmux's startup queries.
    private var outbox: [(seq: UInt32?, bytes: Data?)] = []
    /// The first of `outbox` is partly in the PTY, so nothing may go ahead of it.
    private var midWrite = false
    /// tmux flushes its terminal's input when it takes the terminal over, and only writes after. Bytes in the PTY before
    /// the client's first output would be acked and lost.
    private var clientUp = false
    private var stopped = false

    init(peer: WebSocketPeer, name: String, hub: TerminalHub) {
        self.peer = peer; self.name = name; self.hub = hub; queue = hub.queue
        peer.sent = { [weak self] in self?.drained() }
    }

    // MARK: Socket

    func resolved(_ command: Command) {
        self.command = command
        startIfReady()
    }

    func received(_ message: WebSocketCodec.Message) {
        guard ready else {
            if case .text(let text) = message, !helloed, let control = try? JSONDecoder().decode(TermControl.self, from: Data(text.utf8)),
               case .hello(let viewer, let cols, let rows, let theme) = control {
                guard UUID(uuidString: viewer) != nil else { return peer.close(4426, "viewer isn't a UUID") }
                helloed = true
                recordKey = peer.device + "\n" + viewer
                queries = RemoteTerminal.Queries(theme: theme)
                size(cols, rows)
                startIfReady()
            } else if helloed {
                early.append(message)
            } else {
                peer.close(4426, "hello first")
            }
            return
        }
        switch message {
        case .text(let text):
            switch try? JSONDecoder().decode(TermControl.self, from: Data(text.utf8)) {
            case .resize(let cols, let rows)?:
                size(cols, rows)
                hub?.evaluate(name)
            case .hello?: peer.close(4426, "hello twice")
            default: break
            }
        case .binary(let data):
            guard case .input(let seq, let bytes)? = TermFrame(data) else { return peer.close(4426, "not an input frame") }
            take(seq, bytes)
        default: break
        }
    }

    private func size(_ cols: Int, _ rows: Int) {
        (self.cols, self.rows) = RemoteTerminal.clamp(cols: cols, rows: rows)
        active = Date().timeIntervalSince1970
    }

    private func send(_ control: TermControl) {
        guard let data = try? JSONEncoder().encode(control) else { return }
        peer.send(.text(String(decoding: data, as: UTF8.self)))
    }

    // MARK: Client

    private func startIfReady() {
        guard helloed, !started, !stopped, let command, let key = recordKey, let hub else { return }
        let applied = hub.record(key)
        input = RemoteTerminal.Input(applied: applied ?? 0)
        written = applied ?? 0
        acked = written
        guard spawn(command) else { return peer.close(1011, "couldn't start the terminal") }
        started = true
        ready = true
        // tmux answers attach with the current window; the first evaluation gives the size this view renders at.
        send(.ready(epoch: hub.epoch, applied: applied, cols: cols, rows: rows, owner: "phone"))
        shown = (cols, rows, "phone")
        let early = early
        self.early = []
        for message in early { received(message) }
        hub.evaluate(name)
    }

    private func spawn(_ command: Command) -> Bool {
        let argv = command.args.map { strdup($0) } + [nil]
        let envp = command.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var master: Int32 = -1
        let pid = sidea_pty_spawn(command.path, argv, envp, UInt16(cols), UInt16(rows), &master)
        guard pid > 0 else { return false }
        self.pid = pid
        self.master = master
        queriesUntil = Date().addingTimeInterval(Self.queryWindow)
        let queue = queue
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            queue.async { [weak self] in self?.reaped = true }
        }
        let reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        reader.setEventHandler { [weak self] in self?.read() }
        reader.setCancelHandler { Darwin.close(master) }
        reader.resume()
        self.reader = reader
        return true
    }

    private func read() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(master, &chunk, chunk.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0 else {
            // EOF or EIO: the client exited and the PTY's other end closed.
            reader?.cancel(); reader = nil
            master = -1
            dropOutbox()
            flush()
            hub?.clientGone(self)
            return
        }
        clientUp = true
        var bytes = Data(chunk[..<count])
        if Date() < queriesUntil {
            let filtered = queries.filter(bytes)
            bytes = filtered.forward
            if !filtered.replies.isEmpty { outbox.insert((nil, filtered.replies), at: midWrite ? 1 : 0) }
        } else if queriesUntil != .distantPast {
            queriesUntil = .distantPast
            bytes = queries.flush() + bytes
        }
        buffer += bytes
        if buffer.count >= TermFrame.maxOutput { flush() } else if flushing == nil, !buffer.isEmpty {
            let work = DispatchWorkItem { [weak self] in self?.flush() }
            flushing = work
            queue.asyncAfter(deadline: .now() + Self.coalesce, execute: work)
        }
        if !outbox.isEmpty { pump() }
    }

    private func flush() {
        flushing?.cancel(); flushing = nil
        while !buffer.isEmpty {
            let frame = buffer.prefix(TermFrame.maxOutput)
            buffer = Data(buffer.dropFirst(frame.count))
            peer.send(.binary(TermFrame.output(Data(frame)).data))
        }
        if peer.queued >= Self.pauseAt, !paused, let reader {
            paused = true
            reader.suspend()
        }
    }

    private func drained() {
        guard paused, peer.queued < Self.pauseAt / 2, let reader else { return }
        paused = false
        reader.resume()
    }

    // MARK: Input

    private func take(_ seq: UInt32, _ bytes: Data) {
        switch input.take(seq: seq, bytes: bytes) {
        case .again: if outbox.isEmpty { ack(force: true) }
        case .gap: peer.close(4422, "input gap")
        case .tooLarge: outbox.append((seq, nil)); pump()
        case .write(let bytes):
            hub?.typed(name)
            let latest = hub?.isLatest(self) ?? true
            active = Date().timeIntervalSince1970
            if !latest { hub?.evaluate(name) }
            outbox.append((seq, bytes)); pump()
        }
    }

    /// Writes queued frames in order, each in one write when the PTY takes it, waiting for room when it doesn't.
    private func pump() {
        guard master >= 0 else { return dropOutbox() }
        guard clientUp else { return }
        while let first = outbox.first {
            guard let bytes = first.bytes else {
                outbox.removeFirst()
                if let seq = first.seq {
                    written = seq
                    acked = seq
                    send(.ack(seq: seq, error: "too_large"))
                }
                continue
            }
            let count = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if count < 0, errno == EAGAIN || errno == EINTR { return wait() }
            guard count >= 0 else { return dropOutbox() }
            if count < bytes.count {
                outbox[0].bytes = bytes.dropFirst(count)
                midWrite = midWrite || count > 0
                if first.seq != nil { partial = partial || count > 0 }
                return wait()
            }
            outbox.removeFirst()
            midWrite = false
            if let seq = first.seq {
                partial = false
                written = seq
            }
        }
        if written > acked { ack(force: true) }
    }

    private func dropOutbox() {
        outbox.removeAll()
        midWrite = false
    }

    private func wait() {
        guard writer == nil else { return }
        let writer = DispatchSource.makeWriteSource(fileDescriptor: master, queue: queue)
        writer.setEventHandler { [weak self] in
            self?.writer?.cancel(); self?.writer = nil
            self?.pump()
        }
        writer.resume()
        self.writer = writer
        ack(force: false)
    }

    /// At most every 50 ms, and at once when the outbox drains.
    private func ack(force: Bool) {
        guard written > acked || force else { return }
        if force || acking == nil {
            acking?.cancel(); acking = nil
            if force { acked = written; return send(.ack(seq: written, error: nil)) }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                acking = nil
                if written > acked { acked = written; send(.ack(seq: written, error: nil)) }
            }
            acking = work
            queue.asyncAfter(deadline: .now() + Self.ackEvery, execute: work)
        }
    }

    // MARK: Size and the end

    func show(_ window: TerminalHub.Window) {
        guard started, !stopped else { return }
        let owner = window.size.owner
        if master >= 0 { sidea_pty_resize(master, UInt16(clamping: window.cols), UInt16(clamping: window.rows)) }
        if shown.map({ $0 != (window.cols, window.rows, owner) }) ?? true {
            shown = (window.cols, window.rows, owner)
            send(.size(cols: window.cols, rows: window.rows, owner: owner))
        }
        if copy != window.copy {
            if copy != nil || window.copy { send(.mode(copy: window.copy)) }
            copy = window.copy
        }
    }

    func finish(status: Int?, reason: TermExitReason) {
        send(.exit(status: status, reason: reason))
        peer.close(4410, "session ended")
    }

    /// The socket closed: SIGHUP the client, SIGKILL a second later if it's still there.
    func stop() {
        guard !stopped else { return }
        stopped = true
        flushing?.cancel(); acking?.cancel()
        writer?.cancel(); writer = nil
        if let reader {
            if paused { reader.resume() }
            reader.cancel()
            self.reader = nil
        }
        master = -1
        guard pid > 0 else { return }
        let pid = pid
        kill(pid, SIGHUP)
        queue.asyncAfter(deadline: .now() + 1) { [self] in if !reaped { kill(pid, SIGKILL) } }
    }
}
