import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftUI

@main
struct SideARemoteApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var root: AppRoot
    @State private var lock = AppLock()
    @AppStorage(Accent.key, store: Accent.store) private var accent = Accent.blue
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Launch.mark("app init")
        root = AppRoot(arguments: ProcessInfo.processInfo.arguments)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(root)
                .environment(root.model)
                #if DEBUG
                .overlay {
                    if let sample = NotificationCardSample(arguments: ProcessInfo.processInfo.arguments) { sample }
                    if let gallery = WidgetGallery(arguments: ProcessInfo.processInfo.arguments) { gallery }
                    if let gallery = ActivityGallery(arguments: ProcessInfo.processInfo.arguments) { gallery }
                }
                #endif
                .overlay { PillOverlay() }
                // The lock itself is in `LockWindow`, above every sheet; this keeps the first frame covered until it's up.
                .overlay {
                    if lock.locked { Color(.systemBackground).ignoresSafeArea() }
                }
                .accessibilityHidden(lock.covered)
                .onChange(of: lock.covered, initial: true) { LockWindow.shared.update(lock) }
                // Past xxLarge the layouts break apart, so type stops growing there; smaller sizes scale as usual.
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .tint(accent.color)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            root.setForeground(phase == .active)
            lock.phase(phase)
        }
    }
}

/// The paired Macs, one model each, or none yet; Debug builds launched with `--demo` show sample data for
/// screenshots (`--demo-macs 2` adds a second Mac), and App Review's code opens the same demo in any build
/// (`ReviewDemo`). Pairing adds a Mac, Forget removes one.
@Observable
final class AppRoot {
    nonisolated deinit {}

    /// In the order they were paired; empty before pairing.
    private(set) var macs: [AppModel] { didSet { publishWidgets() } }
    /// Sessions, Accounts and Search show this Mac only; nil shows every Mac. Only matters with more than one.
    var shown: String?
    /// Bumped when the app's whole state changes (paired the first Mac, left the demo, forgot the last Mac),
    /// so nothing carries over.
    private(set) var epoch = 0
    /// Opened by App Review's code: the demo says so on screen, and Settings offers Leave Demo.
    private(set) var reviewing = false
    private let unpaired = AppModel.unpaired()

    /// The first Mac's model, for screens about the app rather than one Mac; unpaired when there's none.
    var model: AppModel { macs.first ?? unpaired }

    /// The shown Mac, or the first.
    var current: AppModel { shown.flatMap(model(for:)) ?? model }

    /// The Macs a screen shows: the one picked, or all of them.
    var visible: [AppModel] { shown.flatMap(model(for:)).map { [$0] } ?? macs }

    func action(for url: URL) -> LinkAction { LinkAction.of(url, pairedMacs: macs.filter { !$0.isDemo }.count) }

    func model(for macID: String) -> AppModel? { macs.first { $0.macID == macID } }

    /// What waits on every Mac, oldest first.
    var waiting: [RemoteRequest] {
        macs.count == 1 ? model.requests.open : macs.flatMap(\.requests.open).sorted { $0.arrivedAt < $1.arrivedAt }
    }

    func model(answering request: RequestID) -> AppModel? {
        macs.first { $0.requests.request(request) != nil }
    }

    /// The Mac a session is on, by its id.
    func model(owning session: SessionKey) -> AppModel? {
        macs.first { $0.sessions.session(session) != nil } ?? macs.first { $0.transcripts.messages[session] != nil }
    }

    init(arguments: [String] = []) {
        #if DEBUG
        let demo = arguments.contains("--demo")
        #else
        let demo = false
        #endif
        if demo {
            macs = [.demo()]
            #if DEBUG
            if let index = arguments.firstIndex(of: "--demo-macs"), index + 1 < arguments.count, arguments[index + 1] == "2" {
                macs.append(.demoSecond())
            }
            if arguments.contains("--demo-stream") { DemoStream.start(model) }
            if arguments.contains("--demo-activity") { DemoActivity.start() }
            // `--attention trust|unsent|screen`: a hosted.attention on Add LAN mode's terminal.
            if let index = arguments.firstIndex(of: "--attention"), index + 1 < arguments.count {
                let kind = HostedAttention.Kind(rawValue: arguments[index + 1])
                let text = switch kind {
                case .trust: "Do you trust the files in this folder?"
                case .unsent: "It may not have been sent."
                default: "It may not have compacted. Look at the session."
                }
                macs[0].tools.show(HostedAttention(name: "sa-side-a-91be", kind: kind, text: text))
            }
            // `--pill Archived`: the pill with Undo, for screenshots.
            if let index = arguments.firstIndex(of: "--pill"), index + 1 < arguments.count {
                let text = arguments[index + 1]
                Launch.afterFirstFrame { Pill.show(text) {} }
            }
            // `--mac-state stale|offline|tailscale|revoked|key`: the demo in a connection state, for screenshots.
            if let index = arguments.firstIndex(of: "--mac-state"), index + 1 < arguments.count {
                let mac = macs[macs.count - 1].mac
                mac.lastSeen = .now.addingTimeInterval(-4 * 60)
                switch arguments[index + 1] {
                case "stale": mac.state = .reconnecting(since: mac.lastSeen)
                case "tailscale": mac.state = .offline(.tailscaleOff)
                case "revoked": mac.state = .offline(.revoked)
                case "key": mac.state = .offline(.keyChanged)
                default: mac.state = .offline(.macUnreachable)
                }
            }
            #endif
        } else {
            macs = PairedMac.all().map(AppModel.live)
        }
        WidgetPublisher.shared.sources = { [weak self] in self?.macs ?? [] }
        Launch.afterFirstFrame { [weak self] in self?.publishWidgets() }
        Launch.mark("models ready", "\(macs.count) Mac\(macs.count == 1 ? "" : "s")")
    }

    /// The demo fills the widgets with its own sessions; unpaired clears them; live Macs publish as their data arrives.
    private func publishWidgets() {
        if model.isDemo || !macs.isEmpty {
            WidgetPublisher.shared.refresh()
        } else {
            WidgetPublisher.shared.clear()
        }
    }

    func setForeground(_ foreground: Bool) {
        if reviewing { foreground ? ReviewDemo.cancelRequest() : ReviewDemo.scheduleRequest() }
        for mac in macs { mac.link?.setForeground(foreground) }
        if foreground { Launch.afterFirstFrame { Task { await Revocations.run() } } }
    }

    /// A new pairing, or Pair Again: that Mac's old link stops and its new one takes its place; other Macs carry on.
    /// Pairing from the demo leaves it.
    func paired(_ mac: PairedMac) {
        let id = mac.endpoint.macID
        if model.isDemo {
            if reviewing { ReviewDemo.end() }
            reviewing = false
            macs = []
            epoch += 1
        }
        if let index = macs.firstIndex(where: { $0.macID == id }) {
            macs[index].link?.stop()
            Paths.forget(macID: id)
            StateCache.remove(id)
            macs[index] = .live(mac)
        } else {
            if macs.isEmpty { epoch += 1 }
            macs.append(.live(mac))
        }
        macs.last?.link?.setForeground(true)
        // The record this one replaces under another id: the same Mac, which had moved on from the id it was paired under.
        for stale in macs where stale.macID != id && stale.tools.answersAs == id { forget(stale.macID) }
    }

    /// App Review's code: the demo in place of any paired Mac, whose links stop until Leave Demo. Notifications are
    /// asked for now, while the reviewer is in the app, and the Live Activity starts at once.
    func openDemo() {
        for mac in macs { mac.link?.stop() }
        macs = [.demo()]
        shown = nil
        reviewing = true
        epoch += 1
        Task {
            await ReviewDemo.askForNotifications()
            ReviewDemo.startActivity()
        }
    }

    /// Settings › Leave Demo: back to the paired Macs, or to the welcome.
    func leaveDemo() {
        ReviewDemo.end()
        reviewing = false
        macs = PairedMac.all().map(AppModel.live)
        epoch += 1
        for mac in macs { mac.link?.setForeground(true) }
    }

    /// Settings › Macs › Forget This Mac: only that Mac goes. Its record goes first, so a relaunch doesn't
    /// bring it back; its token stays until the Mac has heard `DELETE /v1/devices/self` (`Revocations`).
    func forget(_ macID: String) {
        guard let index = macs.firstIndex(where: { $0.macID == macID }) else { return }
        let gone = macs.remove(at: index)
        if shown == macID { shown = nil }
        if macs.isEmpty { epoch += 1 }
        StateCache.remove(macID)
        NotificationPrefs.forget(macID: macID)
        MacNicknames.set(nil, for: macID)
        guard let link = gone.link else { return }
        link.flights.forgetFlights()
        link.mac.forget()
        link.stop()
        Task {
            Paths.forget(macID: macID)
            await Revocations.run()
        }
    }
}
