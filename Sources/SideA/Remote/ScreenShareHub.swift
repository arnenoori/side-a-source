import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import ScreenCaptureKit
import SideACore
import SideAProtocol

/// `/v1/ws/screen/{mode}` (protocol's Screen section): one viewer at a time, capturing only while it is connected and
/// still sending feedback. Everything here runs on the server's queue.
final class ScreenHub: @unchecked Sendable {
    let queue: DispatchQueue
    let share: ScreenShare
    let sessionApp: @MainActor @Sendable (String) async -> pid_t?
    private var viewer: ScreenViewer?

    init(queue: DispatchQueue, share: ScreenShare, sessionApp: @escaping @MainActor @Sendable (String) async -> pid_t?) {
        self.queue = queue; self.share = share; self.sessionApp = sessionApp
    }

    func attach(_ peer: WebSocketPeer, mode raw: String) {
        let mode = ScreenMode(rawValue: raw)
        guard [.view, .control].contains(mode) else { return peer.close(4426, "unknown mode") }
        guard ScreenShare.enabled else { return Self.refuse(peer, .off) }
        guard ScreenAccess.recording else { return Self.refuse(peer, .permission) }
        viewer?.end(.replaced)
        let viewer = ScreenViewer(peer: peer, mode: mode, hub: self)
        self.viewer = viewer
        peer.message = { [weak viewer] message in viewer?.received(message) }
        peer.ending = { [weak self, weak viewer] in
            guard let self, let viewer else { return }
            viewer.stop()
            if self.viewer === viewer { self.viewer = nil }
            let share = share, device = peer.device, order = self.order()
            Task { @MainActor in share.ended(device: device, order: order) }
        }
        RemoteLog.shared("screen: #\(peer.id) device \(peer.device.prefix(6)) opened to \(mode.rawValue) over \(viewer.route.rawValue)")
    }

    func end(_ reason: ScreenRefusal) { viewer?.end(reason) }

    func current(_ viewer: ScreenViewer) -> Bool { self.viewer === viewer }

    /// Began and ended reach the main actor as separate tasks, which may run in either order; this queue's order wins.
    private var told = 0
    func order() -> Int {
        told += 1
        return told
    }

    func controlChanged() { viewer?.checkControl() }

    func stopAll() {
        viewer?.end(.ended)
        viewer?.stop()
        viewer = nil
    }

    static func refuse(_ peer: WebSocketPeer, _ reason: ScreenRefusal, _ detail: String? = nil) {
        send(.refused(ScreenRefused(reason: reason, message: detail ?? reason.message)), to: peer)
        peer.close(UInt16(reason.closeCode), reason.rawValue)
    }

    static func send(_ control: ScreenControl, to peer: WebSocketPeer) {
        guard let data = try? JSONEncoder().encode(control) else { return }
        peer.send(.text(String(decoding: data, as: UTF8.self)))
    }
}

final class ScreenViewer: @unchecked Sendable {
    /// Feedback comes every second; this long without any and the capture stops.
    static let silentFor: TimeInterval = 6
    static let inputRate = 30.0

    let peer: WebSocketPeer
    let mode: ScreenMode
    let route: ScreenRoute
    let limits: ScreenLimits
    private weak var hub: ScreenHub?
    private let queue: DispatchQueue
    private let opened = Date()
    private var hello: ScreenHello?
    private var capture: ScreenCapture?
    private var target: ScreenTarget?
    private var bounds = CGRect.zero
    private var bitrate: Int
    private var wanted: Int
    private var clean = 0
    private var dropped = 0
    private var rtt: Double?
    private var sent = 0
    private var heard = Date()
    private var timer: DispatchSourceTimer?
    private var input: RemotePolicy.TokenBucket
    private var control: ScreenControlState?
    private var generation = 0
    private var stopped = false
    private var deferred: [Int: DispatchWorkItem] = [:]
    private var held = 0
    private var typing: [ScreenControl]?
    /// Held while a capture runs: a watched display that sleeps freezes the picture and may lock the Mac.
    private var awake: IOPMAssertionID = 0
    private var active: IOPMAssertionID = 0
    private var gate: Int { route == .relay ? 128 << 10 : 256 << 10 }

    init(peer: WebSocketPeer, mode: ScreenMode, hub: ScreenHub) {
        self.peer = peer; self.mode = mode; self.hub = hub; queue = hub.queue
        route = peer.source.hasPrefix("tunnel:") ? .relay : .direct
        limits = .on(route)
        bitrate = limits.bitrate * (route == .relay ? 3 : 2) / 5
        wanted = limits.fps
        input = RemotePolicy.TokenBucket(rate: Self.inputRate, burst: Self.inputRate * 2, now: Date().timeIntervalSince1970)
        peer.sent = { [weak self] in self?.pump() }
    }

    func received(_ message: WebSocketCodec.Message) {
        guard !stopped else { return }
        heard = Date()
        guard case .text(let text) = message, let control = try? JSONDecoder().decode(ScreenControl.self, from: Data(text.utf8)) else {
            return peer.close(4426, "text control only")
        }
        guard hello != nil || control.type == "hello" else { return peer.close(4426, "hello first") }
        switch control {
        case .hello(let hello):
            guard self.hello == nil, hello.version >= 1, hello.codecs.contains("h264") else { return peer.close(4426, "unsupported hello") }
            self.hello = hello
            startTimer()
            content { [weak self] content in self?.ready(content) }
        case .start(let start): begin(start)
        case .keyframe: capture?.requestKeyframe(); pump()
        case .feedback(let feedback):
            dropped = min(dropped + min(max(feedback.dropped, 0), 1000), 1_000_000)
            rtt = feedback.rtt
            if feedback.dropped > 0 { capture?.requestKeyframe() }
        case .ping(let t): send(.pong(t: t))
        case .pointer, .scroll, .key, .text: take(control)
        case .bye: peer.close(1000, "")
        default: break
        }
    }

    private func send(_ control: ScreenControl) { ScreenHub.send(control, to: peer) }

    func end(_ reason: ScreenRefusal, _ detail: String? = nil) {
        guard !stopped else { return }
        ScreenHub.refuse(peer, reason, detail)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.cancel(); timer = nil
        deferred.values.forEach { $0.cancel() }; deferred = [:]; typing = nil
        capture?.stop(); capture = nil
        for assertion in [awake, active] where assertion != 0 {
            let released = IOPMAssertionRelease(assertion)
            if released != kIOReturnSuccess { RemoteLog.shared("screen: #\(peer.id) couldn't let the display sleep again (\(released))") }
        }
        awake = 0; active = 0
        peer.sent = nil
        RemoteLog.shared("screen: #\(peer.id) stopped after \(Int(-opened.timeIntervalSinceNow)) s")
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard !stopped else { return }
        if -heard.timeIntervalSinceNow > Self.silentFor { return end(.timeout) }
        refreshBounds()
        adapt()
        checkControl()
    }

    private func content(_ done: @escaping @Sendable (SCShareableContent?) -> Void) {
        if ScreenStandIn.current != nil { return queue.async { done(nil) } }
        Task {
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let shared = Unchecked(content)
            queue.async { done(shared.value) }
        }
    }

    private func ready(_ content: SCShareableContent?) {
        guard !stopped else { return }
        if let stand = ScreenStandIn.current {
            let state = controlState()
            control = state
            RemoteLog.shared("screen: #\(peer.id) ready with the stand-in's screen")
            return send(.ready(ScreenReady(route: route, displays: stand.displays, windows: stand.windows.map(\.info), control: state, limits: limits)))
        }
        guard let content else { return end(.permission) }
        let displays = content.displays.enumerated().map { index, display in
            ScreenDisplay(id: display.displayID, name: CGDisplayIsBuiltin(display.displayID) != 0 ? "Built-in Display" : "Display \(index + 1)",
                          width: display.width, height: display.height, main: display.displayID == CGMainDisplayID())
        }
        let own = ProcessInfo.processInfo.processIdentifier
        let windows = content.windows
            .filter { $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width >= 120 && $0.frame.height >= 80 && $0.owningApplication.map { $0.processID != own } == true }
            .map { ScreenWindow(id: $0.windowID, app: $0.owningApplication?.applicationName ?? "", title: $0.title.flatMap { $0.isEmpty ? nil : $0 },
                                width: Int($0.frame.width), height: Int($0.frame.height)) }
            .sorted { ($0.app, $0.title ?? "") < ($1.app, $1.title ?? "") }
            .prefix(40)
        let state = controlState()
        control = state
        RemoteLog.shared("screen: #\(peer.id) ready with \(displays.count) displays and \(windows.count) windows")
        send(.ready(ScreenReady(route: route, displays: displays, windows: Array(windows), control: state, limits: limits)))
    }

    private func begin(_ start: ScreenStart) {
        RemoteLog.shared("screen: #\(peer.id) start \(start.target.map { "\($0)" } ?? start.session ?? "main display")")
        if let fps = start.fps { wanted = min(limits.fps, max(1, fps)) }
        generation += 1
        let generation = generation
        if let target = start.target { return content { [weak self] in self?.capture(target, in: $0, generation) } }
        if let stand = ScreenStandIn.current, start.session != nil, let window = stand.windows.first {
            return content { [weak self] _ in self?.capture(.window(window.info.id), in: nil, generation) }
        }
        guard let session = start.session, let hub else {
            return content { [weak self] in self?.capture(nil, in: $0, generation) }
        }
        let sessionApp = hub.sessionApp
        Task { [weak self] in
            let pid = await sessionApp(session)
            let target = pid.flatMap(ScreenInput.frontWindow(of:)).map { ScreenTarget.window($0) }
            self?.content { [weak self] in self?.capture(target, in: $0, generation) }
        }
    }

    private func capture(_ target: ScreenTarget?, in content: SCShareableContent?, _ generation: Int) {
        guard !stopped, generation == self.generation, let hello else { return }
        let filter: SCContentFilter?
        let pixels: CGSize
        let chosen: ScreenTarget
        if let stand = ScreenStandIn.current {
            let main = stand.displays.first { $0.main } ?? stand.displays[0]
            switch target {
            case .window(let id)? where stand.bounds(window: id) != nil: (bounds, chosen) = (stand.bounds(window: id) ?? .zero, .window(id))
            case .display(let id)?: (bounds, chosen) = (stand.bounds(display: id), .display(id))
            default: (bounds, chosen) = (stand.bounds(display: main.id), .display(main.id))
            }
            (filter, pixels) = (nil, CGSize(width: bounds.width * 2, height: bounds.height * 2))
        } else {
            guard let content else { return end(.permission) }
            let main = content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
            switch target {
            case .window(let id)?:
                guard let window = content.windows.first(where: { $0.windowID == id }) else {
                    return capture(nil, in: content, generation)
                }
                bounds = ScreenInput.bounds(window: id) ?? window.frame
                let scale = Self.scale(at: CGPoint(x: bounds.midX, y: bounds.midY))
                (filter, pixels, chosen) = (SCContentFilter(desktopIndependentWindow: window), CGSize(width: bounds.width * scale, height: bounds.height * scale), .window(id))
            case .display(let id)?:
                guard let display = content.displays.first(where: { $0.displayID == id }) else { return capture(nil, in: content, generation) }
                (filter, pixels, chosen) = Self.whole(display)
                bounds = ScreenInput.bounds(display: id)
            case nil:
                guard let main else { return end(.failed, "This Mac has no display to show.") }
                (filter, pixels, chosen) = Self.whole(main)
                bounds = ScreenInput.bounds(display: main.displayID)
            }
        }
        capture?.stop()
        ScreenStandIn.current?.shown = bounds
        let size = ScreenCapture.fit(width: Int(pixels.width), height: Int(pixels.height),
                                     longEdge: min(limits.longEdge, max(hello.maxWidth, hello.maxHeight)))
        let capture = ScreenCapture(queue: queue, size: size, fps: fps(for: bitrate), bitrate: bitrate)
        capture.captured = { [weak self] in self?.pump() }
        capture.encoded = { [weak self] config, video in self?.deliver(config, video) }
        capture.stopped = { [weak self] why in
            guard let self, !stopped else { return }
            RemoteLog.shared("screen: #\(peer.id) capture stopped: \(why)")
            if case .window = self.target { self.begin(ScreenStart(fps: wanted)) } else { end(.failed, "The Mac's capture stopped: \(why)") }
        }
        self.capture = capture
        self.target = chosen
        if awake == 0 {
            let held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                   "Side A: a phone is watching this screen" as CFString, &awake)
            if held != kIOReturnSuccess { awake = 0; RemoteLog.shared("screen: #\(peer.id) couldn't keep the display awake (\(held))") }
            // Holding it off doesn't wake a display that already slept, and a sleeping display captures nothing.
            if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
                let woke = IOPMAssertionDeclareUserActivity("Side A: a phone started watching" as CFString, kIOPMUserActiveLocal, &active)
                if woke != kIOReturnSuccess { RemoteLog.shared("screen: #\(peer.id) couldn't wake the display (\(woke))") }
            }
        }
        let shared = Unchecked(filter)
        Task {
            do {
                if let filter = shared.value { try await capture.start(filter) } else if let stand = ScreenStandIn.current { capture.start(standIn: stand) }
                self.queue.async { [self] in self.started(capture, chosen) }
            } catch {
                self.queue.async { [self] in
                    guard self.capture === capture else { return }
                    RemoteLog.shared("screen: #\(peer.id) couldn't start: \((error as NSError).domain) \((error as NSError).code)")
                    if ScreenAccess.recording {
                        end(.failed, "The Mac couldn't capture its screen: \(error.localizedDescription)")
                    } else {
                        end(.permission)
                    }
                }
            }
        }
    }

    private func started(_ capture: ScreenCapture, _ target: ScreenTarget) {
        guard !stopped, self.capture === capture else { return }
        RemoteLog.shared("screen: #\(peer.id) started \(capture.size.width)x\(capture.size.height) at \(capture.fps) fps")
        send(.started(ScreenStarted(target: target, width: capture.size.width, height: capture.size.height, fps: capture.fps)))
        sendQuality()
        guard let hub else { return }
        let share = hub.share, device = peer.device, mode = mode, route = route, order = hub.order()
        Task { @MainActor in share.began(device: device, mode: mode, route: route, order: order) }
    }

    private static func whole(_ display: SCDisplay) -> (SCContentFilter, CGSize, ScreenTarget) {
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let pixels = CGSize(width: mode?.pixelWidth ?? display.width * 2, height: mode?.pixelHeight ?? display.height * 2)
        return (SCContentFilter(display: display, excludingWindows: []), pixels, .display(display.displayID))
    }

    private static func scale(at point: CGPoint) -> CGFloat {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0,
              let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else { return 2 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    private func refreshBounds() {
        guard case .window(let id)? = target, let now = ScreenInput.bounds(window: id), let capture, let hello else { return }
        bounds = now
        let scale = Self.scale(at: CGPoint(x: now.midX, y: now.midY))
        let size = ScreenCapture.fit(width: Int(now.width * scale), height: Int(now.height * scale),
                                     longEdge: min(limits.longEdge, max(hello.maxWidth, hello.maxHeight)))
        if abs(size.width - capture.size.width) > 8 || abs(size.height - capture.size.height) > 8 { capture.set(size: size) }
    }

    private func pump() {
        guard !stopped, let capture, peer.queued < gate else { return }
        capture.pull()
    }

    private func deliver(_ config: ScreenFrame?, _ video: ScreenFrame) {
        guard !stopped, case .video(_, _, _, let data) = video else { return }
        if data.count > ScreenFrame.maxVideo || peer.queued + data.count > WebSocketPeer.maxQueued * 3 / 4 {
            // Dropping it breaks every frame after it, so the next one is a keyframe, at a rate the socket can take.
            capture?.requestKeyframe()
            lower()
            return pump()
        }
        if let config { peer.send(.binary(config.data)) }
        peer.send(.binary(video.data))
        sent += 1
        pump()
    }

    private func fps(for bitrate: Int) -> Int {
        let share = Double(bitrate) / Double(limits.bitrate)
        let tier = share >= 0.5 ? limits.fps : share >= 0.2 ? limits.fps * 2 / 3 : max(5, limits.fps / 3)
        return min(tier, wanted)
    }

    private func lower() {
        bitrate = max(limits.floor, bitrate * 3 / 4)
        clean = 0
        apply()
    }

    private func adapt() {
        guard let capture else { return }
        let skips = capture.takeSkips()
        let late = rtt.map { $0 > (route == .relay ? 700 : 300) } ?? false
        let frames = sent
        sent = 0
        if skips > max(1, capture.fps / 4) || peer.queued >= gate || dropped > 0 || late {
            dropped = 0
            return lower()
        }
        guard frames >= max(2, capture.fps / 4) else { return }
        clean += 1
        guard clean >= 2, bitrate < limits.bitrate else { return }
        clean = 0
        bitrate = min(limits.bitrate, bitrate * 23 / 20)
        apply()
    }

    private func apply() {
        guard let capture else { return }
        let before = (capture.fps, capture.bitrate)
        capture.set(bitrate: bitrate)
        capture.set(fps: fps(for: bitrate))
        if before != (capture.fps, capture.bitrate) { sendQuality() }
    }

    /// The relay's ceiling is a reduction in itself. On the LAN a stream starts at two fifths of the ceiling and climbs only
    /// while frames flow, so a still screen stays there: that is the start, not a socket that drains slowly.
    static func reduced(bitrate: Int, on route: ScreenRoute) -> Bool {
        route == .relay || bitrate < ScreenLimits.on(route).bitrate * 2 / 5
    }

    private func sendQuality() {
        guard let capture else { return }
        send(.quality(ScreenQuality(fps: capture.fps, bitrate: capture.bitrate, width: capture.size.width, height: capture.size.height,
                                    reduced: Self.reduced(bitrate: capture.bitrate, on: route))))
    }

    func checkControl() {
        let state = controlState()
        guard hello != nil, state != control else { return }
        control = state
        send(.control(state))
    }

    private func controlState() -> ScreenControlState {
        guard mode == .control else { return ScreenControlState(allowed: false, reason: .view) }
        guard ScreenShare.controlEnabled else { return ScreenControlState(allowed: false, reason: .off) }
        guard ScreenInput.trusted else { return ScreenControlState(allowed: false, reason: .accessibility) }
        guard !ScreenInput.locked else { return ScreenControlState(allowed: false, reason: .locked) }
        return ScreenControlState(allowed: true)
    }

    private func take(_ event: ScreenControl) {
        guard controlState().allowed, capture != nil, target != nil else { return checkControl() }
        guard input.take(now: Date().timeIntervalSince1970) == nil else { return }
        if case .window = target { refreshBounds() }
        switch event {
        case .pointer(let pointer):
            guard let point = point(pointer.x, pointer.y) else { return }
            raiseIfCovered(point, pointer)
        case .scroll(let scroll):
            guard let point = point(scroll.x, scroll.y), scroll.dx.isFinite, scroll.dy.isFinite else { return }
            ScreenInput.scroll(at: point, dx: scroll.dx * bounds.width, dy: scroll.dy * bounds.height)
        case .key, .text: type(event)
        default: break
        }
    }

    private func point(_ x: Double, _ y: Double) -> CGPoint? {
        guard x.isFinite, y.isFinite, !bounds.isEmpty else { return nil }
        return CGPoint(x: bounds.minX + min(1, max(0, x)) * bounds.width, y: bounds.minY + min(1, max(0, y)) * bounds.height)
    }

    /// A captured window may sit under another, where a click at its place would land on the other one: it comes
    /// forward first, and the click is aimed again once it has.
    private func raiseIfCovered(_ point: CGPoint, _ pointer: ScreenPointer) {
        guard case .window(let id)? = target, ScreenStandIn.current == nil else { return ScreenInput.click(point, kind: pointer.kind) }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let top = windows.first { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, let frame = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: frame as CFDictionary) else { return false }
            return rect.contains(point)
        }
        guard let top, (top[kCGWindowNumber as String] as? CGWindowID) != id else { return ScreenInput.click(point, kind: pointer.kind) }
        raise(id) { [weak self] in
            guard let self, self.may(id) else { return }
            self.refreshBounds()
            guard let point = self.point(pointer.x, pointer.y) else { return }
            ScreenInput.click(point, kind: pointer.kind)
        }
    }

    /// Keys go to whichever app is active on the Mac, not to the window in the picture, so in a window they wait for it
    /// to be the active app's front window, and are dropped, with the phone told, when it can't be made so.
    private func type(_ event: ScreenControl) {
        guard case .window(let id)? = target else { return post(event) }
        if let waiting = typing {
            if waiting.count < 64 { typing?.append(event) }
            return
        }
        if ScreenInput.focused(id) { return post(event) }
        typing = [event]
        raise(id) { [weak self] in
            guard let self else { return }
            let held = typing ?? []
            typing = nil
            if may(id), ScreenInput.focused(id) { return held.forEach(post) }
            guard !stopped, hub?.current(self) == true else { return }
            guard controlState().allowed else { return checkControl() }
            let refused = ScreenControlState(allowed: false, reason: .focus)
            control = refused
            send(.control(refused))
            RemoteLog.shared("screen: #\(peer.id) dropped typing: window \(id) couldn't be brought forward")
        }
    }

    private func post(_ event: ScreenControl) {
        switch event {
        case .key(let press): ScreenInput.press(press)
        case .text(let text): ScreenInput.type(String(text.prefix(ScreenControl.maxText)))
        default: break
        }
    }

    private func raise(_ id: CGWindowID, then: @escaping @Sendable () -> Void) {
        Task { @MainActor in ScreenInput.focus(id) }
        held += 1
        let key = held
        let work = DispatchWorkItem { [weak self] in
            self?.deferred[key] = nil
            then()
        }
        deferred[key] = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func may(_ id: CGWindowID) -> Bool {
        !stopped && hub?.current(self) == true && controlState().allowed && capture != nil && target == .window(id)
            && ScreenInput.bounds(window: id) != nil
    }
}
