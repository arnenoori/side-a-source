import Foundation
import Observation
import SideAProtocol
import SideARemoteKit
import SideARemoteShared

@Observable
final class AppModel {
    nonisolated deinit {}

    let mac: MacConnection
    let sessions: SessionsStore
    let requests: RequestsStore
    let transcripts: TranscriptStore
    let accounts: AccountsStore
    let history: HistoryStore
    let images: ImageStore
    let tools: MacTools
    let deliveryChoices = DeliveryChoices()
    let handoffs = HandoffDrafts()
    @ObservationIgnored var stopResends = StopResends()
    let isDemo: Bool
    var paired: Bool
    var link: LiveLink?
    private var demoID = NotificationAnswer.demoMac

    private(set) var pairing: PairedMac?

    var incidents: [Incident] { link?.state.incidents ?? [] }

    var macID: String { link?.mac.endpoint.macID ?? pairing?.endpoint.macID ?? demoID }

    init(mac: MacConnection, sessions: SessionsStore, requests: RequestsStore, transcripts: TranscriptStore,
         accounts: AccountsStore, history: HistoryStore, isDemo: Bool, paired: Bool, live: MacTools.Live? = nil) {
        self.mac = mac; self.sessions = sessions; self.requests = requests; self.transcripts = transcripts
        self.accounts = accounts; self.history = history; self.isDemo = isDemo; self.paired = paired
        images = ImageStore(isDemo: isDemo)
        tools = MacTools(isDemo ? .demo(.sample(sessions.sessions)) : live.map(MacTools.Mode.live) ?? .unavailable)
        sessions.title = { [weak tools] in tools?.title(for: $0) ?? $0.title }
        tools.onLaunch = { [weak sessions] in sessions?.launch($0.name) }
    }

    static func demo(now: Date = .now) -> AppModel {
        let model = demo(DemoData(now: now), name: "MacBook Pro", id: NotificationAnswer.demoMac, now: now)
        model.mac.route = .wifi
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo-linux") {
            model.mac.reportedName = "build-box"
            model.mac.kind = .linux
        }
        #endif
        return model
    }

    static func demoSecond(now: Date = .now) -> AppModel {
        let model = demo(DemoData(now: now).second, name: "Mac mini", id: "demo-2", now: now)
        model.mac.route = .tailscale
        return model
    }

    private static func demo(_ data: DemoData, name: String, id: String, now: Date) -> AppModel {
        let requests = RequestsStore(data.requests)
        let sessions = SessionsStore(data.sessions, extras: data.extras, macID: id)
        let transcripts = TranscriptStore(data.transcripts, earlier: data.earlier)
        let model = AppModel(mac: MacConnection(name: name, state: .live, lastSeen: now),
                             sessions: sessions, requests: requests, transcripts: transcripts,
                             accounts: AccountsStore(data.accounts, autopilot: data.autopilot), history: HistoryStore(data.history),
                             isDemo: true, paired: true)
        model.demoID = id
        model.mac.onPower = true
        model.mac.portable = id == NotificationAnswer.demoMac
        model.mac.memoryUsed = 21.4
        model.mac.memoryTotal = 36
        model.mac.keepAwake = true
        model.tools.showDemoRotation(data.rotation, outlook: data.autopilot.isEmpty ? nil : data.outlook)
        model.foldAnswers()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--cut-message") { model.cutDemoMessage() }
        #endif
        return model
    }

    #if DEBUG
    private func cutDemoMessage() {
        let session = DemoData.ID.syncTest
        guard var list = transcripts.messages[session], let index = list.lastIndex(where: { $0.role == .assistant }),
              let text = list[index].text else { return }
        let full = list[index]
        let cut = String(text.prefix(while: { $0 != "\n" }))
        list[index] = TranscriptMessage(seq: full.seq, uuid: full.uuid, role: full.role, at: full.at, model: full.model, text: cut,
                                        textTruncated: true)
        transcripts.set(list, hasEarlier: transcripts.earlier[session] ?? 0 > 0, for: session)
        let fails = ProcessInfo.processInfo.arguments.contains("--cut-fails")
        transcripts.onLoadWhole = { _, _ in
            try await Task.sleep(for: .seconds(1.5))
            if fails { throw ToolError.demo }
            return full
        }
    }
    #endif

    /// Fed by the Mac. Without the App Group (a build without its entitlement) the outbox can't
    /// open: the model stays empty and connecting, and its tools refuse every change.
    static func live(_ mac: PairedMac) -> AppModel {
        let outbox = SharedStorage.database.flatMap { try? Outbox(file: $0) }
        let link = outbox.map { LiveLink(mac: mac, outbox: $0) }
        var live: MacTools.Live?
        if let link, let outbox { live = MacTools.Live(engine: link.engine, paired: mac, outbox: outbox) }
        let connection = MacConnection(name: mac.endpoint.name, nickname: MacNicknames.nickname(for: mac.endpoint.macID), state: .connecting, lastSeen: .now)
        connection.kind = mac.endpoint.kind
        connection.portable = MacShapes.portable(mac.endpoint.macID)
        let model = AppModel(mac: connection, sessions: SessionsStore([], macID: mac.endpoint.macID),
                             requests: RequestsStore([]), transcripts: TranscriptStore([:]), accounts: AccountsStore([]),
                             history: HistoryStore([]), isDemo: false, paired: true, live: live)
        model.pairing = mac
        model.foldAnswers()
        if let cache = StateCache.load(mac.endpoint.macID) {
            model.restore(cache)
            Launch.mark("sessions from cache", "\(cache.sessions.count) sessions, \(cache.transcripts.count) transcripts")
        }
        if let link {
            model.link = link
            link.attach(model)
            let engine = link.engine
            model.images.fetch = { id, thumbnail in try await engine.client.image(id, thumbnail: thumbnail) }
        }
        return model
    }

    private func foldAnswers() {
        requests.onResolve = { [weak sessions, weak transcripts] request, outcome in
            guard let id = request.sessionID else { return }
            sessions?.resolve(request.id, in: id)
            transcripts?.record(outcome, for: request, in: id)
        }
    }

    static func unpaired() -> AppModel {
        AppModel(mac: MacConnection(name: "", state: .connecting, lastSeen: .now), sessions: SessionsStore([]),
                 requests: RequestsStore([]), transcripts: TranscriptStore([:]), accounts: AccountsStore([]),
                 history: HistoryStore([]), isDemo: false, paired: false)
    }
}

@Observable
final class MacConnection: Identifiable {
    nonisolated deinit {}

    enum Offline: Equatable {
        case tailscaleOff, macUnreachable, macAsleep, relayRefused, noNetwork, revoked, keyChanged, incompatible(installed: String?), appOutdated

        var needsPairing: Bool { self == .revoked || self == .keyChanged }

        var comesBack: Bool { [.tailscaleOff, .macUnreachable, .macAsleep, .relayRefused, .noNetwork].contains(self) }

        var offersPairAgain: Bool { self == .tailscaleOff || self == .macUnreachable || self == .relayRefused }
    }

    enum State: Equatable {
        case connecting, live, reconnecting(since: Date), offline(Offline)

        var isOffline: Bool { if case .offline = self { true } else { false } }
    }

    var isOffline: Bool { state.isOffline }

    private(set) var shown: State
    @ObservationIgnored private var showing: Task<Void, Never>?
    static let blip: Duration = .milliseconds(800)

    var isAway: Bool {
        switch shown {
        case .reconnecting: true
        case .offline(let reason): reason.comesBack
        default: false
        }
    }

    let id = UUID()
    var reportedName: String
    var nickname: String?
    var name: String { nickname ?? reportedName }
    var kind: HostOS = .macos
    var state: State {
        didSet { if state != oldValue { settle() } }
    }
    var lastSeen: Date
    var onPower: Bool?
    var battery: Int?
    var portable = false
    var memoryUsed: Double?
    var memoryTotal: Double?
    var keepAwake: Bool?
    var vpnUp = true
    var route: Route?

    enum Route: Equatable {
        case wifi, tailscale, relay

        init?(_ path: Paths.Path?) {
            switch path {
            case .relay?: self = .relay
            case .direct(let url)?: self = Tailscale.isTailnet(url.host() ?? "") ? .tailscale : .wifi
            case nil: return nil
            }
        }

        var title: String {
            switch self {
            case .wifi: "Wi\u{2011}Fi"
            case .tailscale: "Tailscale"
            case .relay: "Relay"
            }
        }
    }

    var status: String {
        guard state == .live, let route else { return state.title }
        return "Connected via \(route.title)"
    }

    init(name: String, nickname: String? = nil, state: State, lastSeen: Date) {
        reportedName = name; self.nickname = nickname; self.state = state; self.lastSeen = lastSeen; shown = state
    }

    private func settle() {
        showing?.cancel()
        guard case .reconnecting = state, shown == .live else { return shown = state }
        showing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.blip)
            guard !Task.isCancelled, let self else { return }
            shown = state
        }
    }

    func rename(_ nickname: String?, macID: String, in defaults: UserDefaults = SharedStorage.defaults) {
        MacNicknames.set(nickname, for: macID, in: defaults)
        let next = MacNicknames.nickname(for: macID, in: defaults)
        if self.nickname != next { self.nickname = next }
    }

    func foregrounded(now: Date = .now) {
        switch state {
        case .offline(.macUnreachable), .offline(.noNetwork): state = .reconnecting(since: now)
        case .offline(.tailscaleOff) where vpnUp: state = .reconnecting(since: now)
        default: break
        }
    }
}

enum MacNicknames {
    static let key = "mac.nicknames"

    static func nickname(for macID: String, in defaults: UserDefaults = SharedStorage.defaults) -> String? {
        (defaults.dictionary(forKey: key) as? [String: String])?[macID]
    }

    static func set(_ nickname: String?, for macID: String, in defaults: UserDefaults = SharedStorage.defaults) {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        all[macID] = trimmed?.isEmpty == false ? trimmed : nil
        defaults.set(all, forKey: key)
    }

    static func name(_ reported: String, macID: String, in defaults: UserDefaults = SharedStorage.defaults) -> String {
        nickname(for: macID, in: defaults) ?? reported
    }
}

/// Whether a Mac has a battery, kept so its chip shows a laptop while it is out of reach and says nothing.
enum MacShapes {
    static let key = "mac.portable"

    static func portable(_ macID: String, in defaults: UserDefaults = SharedStorage.defaults) -> Bool {
        (defaults.dictionary(forKey: key) as? [String: Bool])?[macID] ?? false
    }

    static func set(portable: Bool, for macID: String, in defaults: UserDefaults = SharedStorage.defaults) {
        var all = defaults.dictionary(forKey: key) as? [String: Bool] ?? [:]
        guard all[macID] != portable else { return }
        all[macID] = portable
        defaults.set(all, forKey: key)
    }
}

extension MacConnection {
    var symbol: String {
        switch kind {
        case .macos: portable ? "laptopcomputer" : "desktopcomputer"
        case .windows, .wsl: "pc"
        default: "server.rack"
        }
    }
}

extension PairedMac {
    var displayName: String { MacNicknames.name(endpoint.name, macID: endpoint.macID) }
}
