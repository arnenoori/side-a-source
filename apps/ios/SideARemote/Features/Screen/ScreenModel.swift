import Foundation
import Observation
import SideAProtocol
import SideARemoteKit
import SideARemoteShared

/// One look at the Mac's screen: the socket through `ScreenSession`, reconnects with a fresh Face ID signature each, the
/// once-a-second feedback the Mac adapts to, and the clicks and keys while controlling.
@Observable
final class ScreenModel: Identifiable {
    nonisolated deinit {}

    enum Phase: Equatable {
        case connecting, live, reconnecting
        case stopped(Stop)
    }

    enum Stop: Equatable {
        case off(String)
        case permission(String)
        case replaced
        case ended(String)
        case declined
        case pairAgain
        case update
        case failed(String)
    }

    let hosted: String?
    /// What kind of computer is shared, for the words that name it.
    let kind: HostOS
    private(set) var phase: Phase = .connecting
    private(set) var mode: ScreenMode = .view
    private(set) var ready: ScreenReady?
    private(set) var started: ScreenStarted?
    private(set) var quality: ScreenQuality?
    private(set) var control = ScreenControlState(allowed: false, reason: .view)
    private(set) var fps = 0.0
    private(set) var rtt: Double?
    /// Three opens in a row failed: still trying, but the Mac is likely asleep or offline.
    private(set) var unreachable = false

    @ObservationIgnored var frames: ((ScreenFrame) -> Void)?
    @ObservationIgnored private let session: ScreenSession?
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var shown = 0
    @ObservationIgnored private var dropped = 0
    @ObservationIgnored private var target: ScreenTarget?
    @ObservationIgnored private var closed = true
    @ObservationIgnored private let needsKeys: Bool
    @ObservationIgnored private var keyAsked = Date.distantPast

    static let hello = ScreenHello(maxWidth: 2560, maxHeight: 2560)

    /// `screenOn` false: the Mac said its switch is off, so no Face ID is asked for until the person tries anyway.
    init(session: ScreenSession?, hosted: String?, screenOn: Bool, needsKeys: Bool, kind: HostOS = .macos) {
        self.session = session; self.hosted = hosted; self.needsKeys = needsKeys; self.kind = kind
        if session == nil { phase = .stopped(.failed("Connect to \(kind.your()) to see its screen.")) }
        else if !screenOn { phase = .stopped(.off(Self.words(.off, kind))) }
    }

    static let offMessage = ScreenRefusal.off.message

    /// The refusal's words when only its close code arrived. The package's are about a Mac; a host that isn't one sends its own.
    static func words(_ reason: ScreenRefusal, _ kind: HostOS) -> String {
        guard !kind.isMac else { return reason.message }
        switch reason {
        case .off: return "Screen sharing is off on \(kind.the())."
        case .permission: return "Side A isn't allowed to capture the screen on \(kind.the())."
        case .ended: return "Ended on \(kind.the())."
        case .timeout: return "\(kind.sentenceThe()) stopped hearing from this \(ThisDevice.kind)."
        default: return "\(kind.sentenceThe()) couldn't capture its screen."
        }
    }

    var controlling: Bool { mode == .control && control.allowed && phase == .live }

    func start() {
        guard let session, closed else { return }
        if case .stopped = phase { return }
        if phase == .live { phase = .reconnecting }
        closed = false
        events = Task { [weak self] in
            for await event in session.events {
                guard let self else { return }
                self.handle(event)
            }
        }
        connect()
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    private func halt(_ stop: Stop) {
        phase = .stopped(stop)
        ticker?.cancel(); ticker = nil
    }

    /// Off screen or in the background: the Mac stops capturing now, not when it notices the silence.
    func stop() {
        guard !closed else { return }
        closed = true
        opening?.cancel()
        events?.cancel(); events = nil
        ticker?.cancel(); ticker = nil
        Task { [session] in await session?.bye() }
    }

    /// Try again from a stopped state, such as after turning the switch on at the Mac.
    func retry() {
        attempt = 0
        phase = .connecting
        if closed { start() } else { connect() }
    }

    func setControl(_ on: Bool) {
        guard on != (mode == .control) else { return }
        guard on else {
            mode = .view
            return reopen()
        }
        Task {
            guard await OwnerAuth.confirm(reason: "Control \(kind.your())") else { return }
            mode = .control
            reopen()
        }
    }

    func show(_ target: ScreenTarget) {
        self.target = target
        Task { [session] in await session?.send(.start(ScreenStart(target: target))) }
    }

    private func reopen() {
        phase = .connecting
        connect()
    }

    private func connect() {
        guard let session, !closed else { return }
        // A stop let the ticker go; Try Again and Control open again on the same socket model.
        if ticker == nil { startTicker() }
        opening?.cancel()
        let mode = mode
        opening = Task { [weak self] in
            do {
                try await session.open(mode, hello: Self.hello)
            } catch is ScreenSession.Unsigned {
                self?.halt(self?.needsKeys == true ? .pairAgain : .declined)
            } catch {
                guard let self, !self.closed, !Task.isCancelled else { return }
                self.schedule()
            }
        }
    }

    private func schedule() {
        if case .stopped = phase { return }
        phase = phase == .connecting && attempt == 0 ? .connecting : .reconnecting
        let delay = min(10, 0.5 * pow(2, Double(attempt)))
        attempt += 1
        unreachable = attempt >= 3
        opening = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func handle(_ event: ScreenSession.Event) {
        switch event {
        case .frame(let frame):
            if case .video = frame { shown += 1 }
            frames?(frame)
        case .control(let control): handle(control)
        case .closed(let code): socketClosed(code)
        }
    }

    private func handle(_ message: ScreenControl) {
        switch message {
        case .ready(let ready):
            self.ready = ready
            control = ready.control
            attempt = 0
            unreachable = false
            Task { [session, target, hosted] in await session?.send(.start(ScreenStart(target: target, session: target == nil ? hosted : nil))) }
        case .started(let started):
            self.started = started
            target = started.target
            phase = .live
        case .quality(let quality): self.quality = quality
        case .control(let state): control = state
        case .pong(let t): rtt = (Date().timeIntervalSince1970 - t) * 1000
        case .refused(let refused): halt(Self.stop(refused))
        default: break
        }
    }

    private static func stop(_ refused: ScreenRefused) -> Stop {
        switch refused.reason {
        case .off: .off(refused.message)
        case .permission: .permission(refused.message)
        case .replaced: .replaced
        case .ended: .ended(refused.message)
        default: .failed(refused.message)
        }
    }

    private func socketClosed(_ code: Int) {
        if case .stopped = phase { return }
        switch ScreenClose(code: code) {
        case .refused(let reason): halt(Self.stop(ScreenRefused(reason: reason, message: Self.words(reason, kind))))
        case .unauthorized: halt(.pairAgain)
        case .unsupported: halt(.update)
        case .closed where closed: break
        case .closed, .lost: schedule()
        }
    }

    // MARK: Feedback and input

    /// At most twice a second: every frame until the keyframe arrives fails the same way.
    func needKeyframe() {
        guard -keyAsked.timeIntervalSinceNow > 0.5 else { return }
        keyAsked = .now
        dropped += 1
        Task { [session] in await session?.send(.keyframe) }
    }

    private func tick() {
        guard phase == .live, let session else { return }
        fps = Double(shown)
        let report = ScreenFeedback(fps: Double(shown), dropped: dropped, rtt: rtt)
        shown = 0
        dropped = 0
        Task {
            await session.send(.feedback(report))
            await session.send(.ping(t: Date().timeIntervalSince1970))
        }
    }

    func send(_ input: ScreenControl) {
        guard controlling, let session else { return }
        Task { await session.send(input) }
    }

    func type(_ text: String) {
        var rest = Substring(text)
        while !rest.isEmpty {
            send(.text(String(rest.prefix(ScreenControl.maxText))))
            rest = rest.dropFirst(ScreenControl.maxText)
        }
    }
}
