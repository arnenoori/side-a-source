import Foundation
import SideAProtocol

/// One look at the Mac's screen on `/v1/ws/screen/{mode}`. Nothing is replayed across sockets: a new one starts with a
/// keyframe, so a reconnect only has to open again.
public actor ScreenSession {
    public enum Event: Sendable {
        case control(ScreenControl)
        case frame(ScreenFrame)
        case closed(code: Int)
    }

    /// No signature: Face ID was declined, or this pairing has no key the Mac takes.
    public struct Unsigned: Error, Sendable {}

    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let client: RemoteClient
    private let confirm: (@Sendable (ScreenMode) async -> String?)?
    private var socket: (any SocketConnection)?
    private var reader: Task<Void, Never>?
    private var connection = 0

    public init(client: RemoteClient, confirm: (@Sendable (ScreenMode) async -> String?)?) {
        self.client = client; self.confirm = confirm
        (events, continuation) = AsyncStream.makeStream()
    }

    public func open(_ mode: ScreenMode, hello: ScreenHello) async throws {
        // Face ID and the connection are awaited, and this actor lets another call in meanwhile: the newest open wins and an
        // older one that wakes up later drops out, or it would leave a socket the Mac has already replaced as the phone's own.
        close()
        let current = connection
        guard let header = await confirm?(mode) else { throw Unsigned() }
        guard connection == current else { return }
        let socket = try await client.socket("/v1/ws/screen/\(mode.rawValue)", confirm: header)
        guard connection == current else { return socket.close(code: 1000, reason: nil) }
        // Read first: a Mac that refuses (Screen off, no permission) says why and closes the moment the socket opens, which can
        // be before the hello goes out. Failing here would send the phone round its retry loop instead of showing the reason.
        reader = Task { await self.read(socket, current) }
        do { try await send(.hello(hello), on: socket) } catch {
            KitLog.log(.transport, "screen hello not sent: \(error)")
        }
        // Published after the hello: a goodbye or a feedback report sent first would be the Mac's "hello first" and end it.
        guard connection == current else { return socket.close(code: 1000, reason: nil) }
        self.socket = socket
    }

    /// Dropped while no socket is open: the phone's input never waits to land later on a Mac that moved on.
    public func send(_ control: ScreenControl) async {
        guard let socket else { return }
        do { try await send(control, on: socket) } catch {
            KitLog.log(.transport, "screen input send failed: \(error)")
        }
    }

    public func close() {
        connection += 1
        reader?.cancel()
        reader = nil
        socket?.close(code: 1000, reason: nil)
        socket = nil
    }

    /// No one will read this session again: its events end, so whoever waits on them can let go.
    public func finish() {
        close()
        continuation.finish()
    }

    /// Says goodbye first, so the Mac stops capturing at once rather than when the socket times out.
    public func bye() async {
        await send(.bye)
        close()
    }

    private func read(_ socket: any SocketConnection, _ current: Int) async {
        do {
            while !Task.isCancelled {
                switch try await socket.receive() {
                case .data(let data):
                    if let frame = ScreenFrame(data) { continuation.yield(.frame(frame)) }
                case .text(let text):
                    if let control = try? JSONDecoder().decode(ScreenControl.self, from: Data(text.utf8)) { continuation.yield(.control(control)) }
                }
            }
        } catch let closed as SocketClosed {
            guard connection == current else { return }
            self.socket = nil
            continuation.yield(.closed(code: closed.code))
        } catch {
            guard connection == current else { return }
            self.socket = nil
            continuation.yield(.closed(code: 1006))
        }
    }

    private func send(_ control: ScreenControl, on socket: any SocketConnection) async throws {
        try await socket.send(.text(String(decoding: try RemoteClient.encoder.encode(control), as: UTF8.self)))
    }
}
