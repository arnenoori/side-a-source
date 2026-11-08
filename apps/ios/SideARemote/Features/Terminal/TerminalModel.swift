import Foundation
import Observation
import SideAProtocol
import SideARemoteKit

/// One terminal view of a hosted session: the socket through `TerminalSession`, reconnects, and the
/// order keys leave in. Keys typed while the socket is down wait here (they were never sent, so sending
/// them later can't repeat anything); keys already sent are the Kit's to resend or drop.
@Observable
final class TerminalModel {
    nonisolated deinit {}

    enum Phase: Equatable {
        case attaching, live, reconnecting
        case ended(String)
    }

    let name: String
    private(set) var phase: Phase = .attaching
    /// The size the Mac renders at, and who set it.
    private(set) var size: (cols: Int, rows: Int, owner: String)?
    /// The Mac is in tmux copy mode.
    private(set) var copyMode = false
    /// Shown in the terminal view until dismissed: keys that may not have arrived, a paste too large.
    var notice: String?
    /// What the session may put on the clipboard (OSC 52): asked once, then kept for this terminal.
    var clipboard: ClipboardPermission = .ask

    enum ClipboardPermission { case ask, allowed, denied }

    /// Fed with output; the view sets it.
    @ObservationIgnored var output: ((ArraySlice<UInt8>) -> Void)?
    /// Asked for the current grid when (re)connecting.
    @ObservationIgnored var grid: () -> (cols: Int, rows: Int) = { (80, 24) }

    @ObservationIgnored private let session: TerminalSession?
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var reconnect: Task<Void, Never>?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var waiting: [Data] = []
    @ObservationIgnored private var waitingBytes = 0
    @ObservationIgnored private var sending = false
    /// A `.drained` or `ready` that came while a send was running, which that send may have refused just before.
    @ObservationIgnored private var sendAgain = false
    @ObservationIgnored private var pendingOutput: [UInt8] = []
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var closed = false

    static let maxWaiting = 64 * 1024
    static let theme = TermTheme(appearance: .dark, fg: "#E6E8E6", bg: "#0F1312")

    /// Nil `session` in the demo: a static screen and no keys go anywhere.
    init(name: String, session: TerminalSession?) {
        self.name = name; self.session = session
        if session == nil { phase = .live }
    }

    /// A UUID per (device, terminal view), kept across launches, so the Mac recognizes this viewer.
    static func viewer(for name: String, mac: String? = nil, defaults: UserDefaults = .standard) -> String {
        // Two Macs can each host a session of the same name.
        let key = "terminal.viewer.\(mac.map { "\($0)." } ?? "")\(name)"
        if let id = defaults.string(forKey: key) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: key)
        return id
    }

    func start() {
        guard let session, events == nil else { return }
        closed = false
        events = Task { [weak self] in
            for await event in session.events {
                guard let self else { return }
                self.handle(event)
            }
        }
        connect()
    }

    func stop() {
        closed = true
        reconnect?.cancel()
        events?.cancel()
        events = nil
        Task { [session] in await session?.close() }
    }

    private func connect() {
        guard let session, !closed else { return }
        reconnect?.cancel()
        let grid = grid()
        reconnect = Task { [weak self] in
            // Typing into a session needs its owner: Face ID or the passcode, held for a few minutes, and
            // asked again on a reconnect after that.
            guard await OwnerAuth.confirm(reason: "Type into \(self?.name ?? "the session") on your Mac") else {
                self?.phase = .ended("Face ID or your passcode is needed to use the terminal.")
                return
            }
            do {
                try await session.open(cols: grid.cols, rows: grid.rows, theme: Self.theme)
            } catch {
                guard let self, !self.closed else { return }
                if case .ended = self.phase { return }
                self.schedule()
            }
        }
    }

    private func schedule() {
        phase = phase == .attaching ? .attaching : .reconnecting
        let delay = min(10, 0.5 * pow(2, Double(attempt)))
        attempt += 1
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func handle(_ event: TerminalSession.Event) {
        switch event {
        case .output(let data):
            pendingOutput.append(contentsOf: data)
            scheduleFlush()
        case .size(let cols, let rows, let owner):
            // The first size after `ready`: the Mac confirmed this connection.
            size = (cols, rows, owner)
            if phase != .live {
                phase = .live
                attempt = 0
            }
            // Also after the Kit reopened on a new path by itself, where the phase never left live.
            sendWaiting()
        case .drained: sendWaiting()
        case .copyMode(let on): copyMode = on
        case .notice(let text): notice = text
        case .exit(_, let reason):
            phase = .ended(reason == .killed ? "The session was ended." : "The session ended.")
        case .closed(let code):
            switch code {
            case 4410, 4404: if case .ended = phase {} else { phase = .ended("The session ended.") }
            case 4401: phase = .ended("This iPhone isn't paired anymore.")
            case 4426: phase = .ended("Update Side A to use the terminal.")
            case 4409: phase = .ended("Open on too many screens. Close one and try again.")
            case 1000 where closed: break
            default: if case .ended = phase {} else { schedule() }
            }
        }
    }

    /// Output lands on the next frame in one piece, however many socket frames brought it.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(8))
            guard let self else { return }
            self.flushScheduled = false
            let bytes = self.pendingOutput
            self.pendingOutput = []
            self.output?(bytes[...])
        }
    }

    // MARK: Input

    /// Keys in order. False when the view must stop taking them: too much is waiting.
    @discardableResult func send(_ bytes: Data) -> Bool {
        guard session != nil, !bytes.isEmpty else { return session == nil }
        if case .ended = phase { return false }
        guard waitingBytes + bytes.count <= Self.maxWaiting else { return false }
        waiting.append(bytes)
        waitingBytes += bytes.count
        sendWaiting()
        return true
    }

    func send(_ bytes: [UInt8]) { send(Data(bytes)) }

    private func sendWaiting() {
        if sending { sendAgain = true }
        guard let session, !sending, phase == .live, !waiting.isEmpty else { return }
        sending = true
        Task { [weak self] in
            while let self, self.phase == .live, let next = self.waiting.first {
                // Not taken: kept until `.drained` (acks made room), or the next `ready` after a dropped socket's `.closed`.
                guard await session.input(next) else { break }
                self.waiting.removeFirst()
                self.waitingBytes -= next.count
            }
            guard let self else { return }
            self.sending = false
            if self.sendAgain {
                self.sendAgain = false
                self.sendWaiting()
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        guard let session, phase == .live else { return }
        Task { await session.resize(cols: cols, rows: rows) }
    }
}
