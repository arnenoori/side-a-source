import SideARemoteShared
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
        case ended(TerminalEnd)
    }

    let name: String
    var kind: HostOS = .macos
    private(set) var phase: Phase = .attaching
    private(set) var size: (cols: Int, rows: Int, owner: String)?
    private(set) var copyMode = false
    var notice: String?
    var clipboard: ClipboardPermission = .ask

    enum ClipboardPermission { case ask, allowed, denied }

    @ObservationIgnored var output: ((ArraySlice<UInt8>) -> Void)?
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

    init(name: String, session: TerminalSession?) {
        self.name = name; self.session = session
        if session == nil { phase = .live }
    }

    static func viewer(for name: String, mac: String? = nil, defaults: UserDefaults = .standard) -> String {
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
            guard await OwnerAuth.confirm(reason: "Type into \(self?.name ?? "the session") on \(self?.kind.your() ?? HostOS.macos.your())") else {
                self?.phase = .ended(.notUnlocked)
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

    /// Asks again after a refusal the person can fix (a cancelled unlock, a screen left open elsewhere).
    func retry() {
        guard case .ended(let end) = phase, end.canRetry, !closed else { return }
        phase = .attaching
        attempt = 0
        connect()
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
            size = (cols, rows, owner)
            if phase != .live {
                phase = .live
                attempt = 0
            }
            sendWaiting()
        case .drained: sendWaiting()
        case .copyMode(let on): copyMode = on
        case .notice(let text): notice = text
        case .exit(_, let reason):
            phase = .ended(.exited(killed: reason == .killed))
        case .closed(let code):
            switch code {
            case 1000 where closed: break
            default:
                if let end = TerminalEnd(closeCode: code) {
                    // An exit already on screen keeps its own words; a refusal replaces them.
                    if end == .exited(killed: false), case .ended = phase { break }
                    phase = .ended(end)
                } else if case .ended = phase {} else { schedule() }
            }
        }
    }

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
