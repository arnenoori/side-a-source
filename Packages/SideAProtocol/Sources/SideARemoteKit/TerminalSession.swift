import Foundation
import SideAProtocol

/// One terminal view of a hosted session on `/v1/ws/term/{name}`. Input is numbered and kept in the
/// shared store until acked, so a reconnect in the same epoch resends exactly what didn't arrive; after
/// Side A restarts, or once the Mac has forgotten this viewer, unacked input is thrown away instead,
/// because a frame that carried Enter may already have run.
public actor TerminalSession {
    public enum Event: Sendable, Equatable {
        case output(Data)
        /// The size to lay out at; `owner` is "mac" or "phone".
        case size(cols: Int, rows: Int, owner: String)
        case copyMode(Bool)
        case exit(status: Int?, reason: TermExitReason)
        /// Something to show in the terminal view, e.g. keys that may not have arrived.
        case notice(String)
        case closed(code: Int)
    }

    public static let maxUnacked = 256 * 1024
    public static let restartNotice = "Side A restarted. Some keys may not have reached the session."

    public let name: String
    /// A UUID per (device, terminal view), kept across reconnects.
    public let viewer: String
    public nonisolated let events: AsyncStream<Event>

    private let client: RemoteClient
    private let outbox: Outbox
    private let continuation: AsyncStream<Event>.Continuation
    private var socket: (any SocketConnection)?
    private var reader: Task<Void, Never>?
    private var connection = 0
    private var epoch: String?
    private var nextSeq: UInt32 = 1
    private var unacked: [(seq: UInt32, epoch: String, bytes: Data)] = []
    private var loaded = false
    /// The current socket's `ready` arrived: until then nothing is sent, so no frame goes out under an epoch
    /// the Mac hasn't confirmed and nothing is replayed except by `ready` itself.
    private var isReady = false
    /// What the last `open` asked for, to open again the same way when the path moves.
    private var opened: (cols: Int, rows: Int, theme: TermTheme?)?

    /// Signs each open (`X-SideA-Confirm`, purpose `.terminal`): the Mac lets only the owner into a terminal.
    private let confirm: (@Sendable (String) async -> String?)?

    public init(client: RemoteClient, name: String, viewer: String, outbox: Outbox, confirm: (@Sendable (String) async -> String?)? = nil) {
        self.client = client; self.name = name; self.viewer = viewer; self.outbox = outbox; self.confirm = confirm
        (events, continuation) = AsyncStream.makeStream()
    }

    /// Connects (or reconnects) and says hello; input is accepted once the Mac answers `ready`.
    public func open(cols: Int, rows: Int, theme: TermTheme? = nil) async throws {
        if !loaded {
            unacked = await outbox.terminalInput(viewer: viewer)
            epoch = unacked.last?.epoch
            nextSeq = (unacked.last?.seq ?? 0) + 1
            loaded = true
        }
        close()
        isReady = false
        opened = (cols, rows, theme)
        let socket = try await client.socket("/v1/ws/term/\(name)", confirm: await confirm?(name))
        self.socket = socket
        connection += 1
        let current = connection
        try await send(.hello(viewer: viewer, cols: cols, rows: rows, theme: theme), on: socket)
        reader = Task { await self.read(socket, current) }
    }

    public func close() {
        reader?.cancel()
        reader = nil
        socket?.close(code: 1000, reason: nil)
        socket = nil
    }

    public func resize(cols: Int, rows: Int) async {
        guard let socket else { return }
        try? await send(.resize(cols: cols, rows: rows), on: socket)
    }

    /// Sends keys or a paste, split into frames of at most 16 KiB. False when the view must stop
    /// taking keys: not connected yet, or 256 KiB already wait for acks.
    @discardableResult public func input(_ bytes: Data) async -> Bool {
        guard let socket, isReady, let epoch, unacked.reduce(0, { $0 + $1.bytes.count }) + bytes.count <= Self.maxUnacked else { return false }
        for frame in TermFrame.inputs(bytes, from: nextSeq) {
            guard case .input(let seq, let part) = frame else { continue }
            unacked.append((seq, epoch, part))
            await outbox.addTerminalInput(viewer: viewer, seq: seq, epoch: epoch, bytes: part)
            nextSeq = seq &+ 1
            try? await socket.send(.data(frame.data))
        }
        return true
    }

    private func read(_ socket: any SocketConnection, _ current: Int) async {
        do {
            while !Task.isCancelled {
                switch try await socket.receive() {
                case .data(let data):
                    if case .output(let bytes)? = TermFrame(data) { continuation.yield(.output(bytes)) }
                case .text(let text):
                    guard let control = try? JSONDecoder().decode(TermControl.self, from: Data(text.utf8)) else { continue }
                    await handle(control, socket)
                }
            }
        } catch let closed as SocketClosed {
            // A socket replaced by a reconnect closes quietly; only the current one's end is news.
            guard connection == current else { return }
            self.socket = nil
            isReady = false
            // The path moved (LAN to relay, say): open again on the new one, which resends what wasn't acked.
            if closed.code == 4008, let opened, (try? await open(cols: opened.cols, rows: opened.rows, theme: opened.theme)) != nil {
                return
            }
            continuation.yield(.closed(code: closed.code))
        } catch {
            guard connection == current else { return }
            continuation.yield(.closed(code: 1006))
        }
    }

    private func handle(_ control: TermControl, _ socket: any SocketConnection) async {
        switch control {
        case .ready(let epoch, let applied, let cols, let rows, let owner):
            await ready(epoch: epoch, applied: applied, socket)
            continuation.yield(.size(cols: cols, rows: rows, owner: owner))
        case .ack(let seq, let error):
            unacked.removeAll { $0.seq <= seq }
            await outbox.dropTerminalInput(viewer: viewer, through: seq)
            if error == "too_large" { continuation.yield(.notice("That paste was too large to send.")) }
        case .size(let cols, let rows, let owner):
            continuation.yield(.size(cols: cols, rows: rows, owner: owner))
        case .mode(let copy):
            continuation.yield(.copyMode(copy))
        case .exit(let status, let reason):
            continuation.yield(.exit(status: status, reason: reason))
        default:
            break
        }
    }

    /// Resend what the Mac didn't apply, or discard it all when delivery can't be known.
    func ready(epoch: String, applied: UInt32?, _ socket: any SocketConnection) async {
        let uncertain = applied == nil || unacked.contains { $0.epoch != epoch } || (self.epoch.map { $0 != epoch } ?? false)
        self.epoch = epoch
        defer { isReady = true }
        if uncertain {
            if !unacked.isEmpty { continuation.yield(.notice(Self.restartNotice)) }
            unacked = []
            await outbox.dropTerminalInput(viewer: viewer)
            nextSeq = 1
            return
        }
        let applied = applied ?? 0
        unacked.removeAll { $0.seq <= applied }
        await outbox.dropTerminalInput(viewer: viewer, through: applied)
        if unacked.isEmpty { nextSeq = applied &+ 1 }
        for frame in unacked { try? await socket.send(.data(TermFrame.input(seq: frame.seq, bytes: frame.bytes).data)) }
    }

    private func send(_ control: TermControl, on socket: any SocketConnection) async throws {
        try await socket.send(.text(String(decoding: try RemoteClient.encoder.encode(control), as: UTF8.self)))
    }
}
