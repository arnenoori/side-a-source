import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftUI

@main
struct SideARemoteApp: App {
    /// This app's page. The id is what the App Store opens by; a name alone finds nothing.
    static let appStore = URL(string: "itms-apps://apps.apple.com/app/id6824351581")!

    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var root: AppRoot
    @State private var lock = AppLock()
    @State private var keys = KeyRequests()
    @AppStorage(Accent.key, store: SharedStorage.defaults) private var accent = Accent.blue
    @AppStorage(Theme.key, store: SharedStorage.defaults) private var theme = Theme.system
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Launch.mark("app init")
        root = AppRoot(arguments: ProcessInfo.processInfo.arguments)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .measuresWindow()
                .environment(keys)
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
                .overlay {
                    if lock.locked { Color(.systemBackground).ignoresSafeArea() }
                }
                .accessibilityHidden(lock.covered)
                .onChange(of: lock.covered, initial: true) { LockWindow.shared.update(lock) }
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .tint(accent.color)
                .preferredColorScheme(theme.scheme)
        }
        .commands { RemoteCommands(keys: keys, lock: lock) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            root.setForeground(phase == .active)
            lock.phase(phase)
            if phase == .active { DeviceBiometry.shared.refresh() }
        }
    }
}

@Observable
final class AppRoot {
    nonisolated deinit {}

    private(set) var macs: [AppModel] { didSet { publishWidgets() } }
    var shown: String? { didSet { if shown != oldValue, !model.isDemo { ListPrefsStore.setShown(shown) } } }
    var newSession = NewSessionForm()
    private(set) var epoch = 0
    private(set) var reviewing = false
    private let unpaired = AppModel.unpaired()

    var model: AppModel { macs.first ?? unpaired }

    var current: AppModel { shown.flatMap(model(for:)) ?? model }

    var visible: [AppModel] { shown.flatMap(model(for:)).map { [$0] } ?? macs }

    var canStartSession: Bool { visible.contains { $0.tools.can(.hosted) } }

    func action(for url: URL) -> LinkAction { LinkAction.of(url, pairedMacs: macs.filter { !$0.isDemo }.count) }

    func model(for macID: String) -> AppModel? { macs.first { $0.macID == macID } }

    var waiting: [RemoteRequest] {
        macs.count == 1 ? model.requests.open : macs.flatMap(\.requests.open).sorted { $0.arrivedAt < $1.arrivedAt }
    }

    func model(answering request: RequestID) -> AppModel? {
        macs.first { $0.requests.request(request) != nil }
    }

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
            if let index = arguments.firstIndex(of: "--attention"), index + 1 < arguments.count {
                let kind = HostedAttention.Kind(rawValue: arguments[index + 1])
                let text = switch kind {
                case .trust: "Do you trust the files in this folder?"
                case .unsent: "It may not have been sent."
                default: "It may not have compacted. Look at the session."
                }
                macs[0].tools.show(HostedAttention(name: "sa-side-a-91be", kind: kind, text: text))
            }
            if let index = arguments.firstIndex(of: "--pill"), index + 1 < arguments.count {
                let text = arguments[index + 1]
                Launch.afterFirstFrame { Pill.show(text) {} }
            }
            if arguments.contains("--clipboard-image") {
                UIPasteboard.general.image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { context in
                    UIColor.systemOrange.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
                }
            }
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
            shown = Self.storedShown(in: macs)
        }
        WidgetPublisher.shared.sources = { [weak self] in self?.macs ?? [] }
        Launch.afterFirstFrame { [weak self] in self?.publishWidgets() }
        Launch.mark("models ready", "\(macs.count) Mac\(macs.count == 1 ? "" : "s")")
    }

    private static func storedShown(in macs: [AppModel]) -> String? {
        ListPrefsStore.shown().flatMap { id in macs.contains { $0.macID == id } ? id : nil }
    }

    private func publishWidgets() {
        if model.isDemo || !macs.isEmpty {
            WidgetPublisher.shared.refresh()
        } else {
            WidgetPublisher.shared.clear()
        }
    }

    func setForeground(_ foreground: Bool) {
        if reviewing { if foreground { ReviewDemo.cancelRequest() } else { ReviewDemo.scheduleRequest() } }
        if foreground { relinkMacs() }
        if foreground { takeNotificationDrafts() }
        for mac in macs { mac.link?.setForeground(foreground) }
        if foreground { Launch.afterFirstFrame { Task { await Revocations.run() } } }
    }

    func takeNotificationDrafts() {
        for mac in macs where !mac.isDemo {
            for (session, text) in NotificationDrafts.take(mac: mac.macID) {
                mac.transcripts.drafts[session] = NotificationDrafts.joined(mac.transcripts.drafts[session], text)
            }
        }
    }

    /// A Mac whose outbox wouldn't open (a launch before the first unlock) stays connecting for good; now the app is
    /// in front, its model is built again.
    private func relinkMacs() {
        for index in macs.indices where macs[index].link == nil && !macs[index].isDemo {
            guard let pairing = macs[index].pairing else { continue }
            macs[index] = .live(pairing)
        }
    }

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
        for stale in macs where stale.macID != id && stale.tools.answersAs == id { forget(stale.macID) }
    }

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

    func leaveDemo() {
        ReviewDemo.end()
        reviewing = false
        macs = PairedMac.all().map(AppModel.live)
        shown = Self.storedShown(in: macs)
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
        ListPrefsStore.forget(mac: macID)
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
