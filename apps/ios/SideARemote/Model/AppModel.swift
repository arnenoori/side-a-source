import Foundation
import Observation
import SideAProtocol
import SideARemoteKit
import SideARemoteShared

/// One Mac's model, which the app injects with `.environment`; with several Macs, each screen about one Mac
/// gets its own. Sub-stores are separate observable objects, so a view that reads only `accounts` re-renders
/// only when accounts change.
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
    /// Fictional data, no network, nothing written outside the app's own container.
    let isDemo: Bool
    var paired: Bool
    /// The connection to the paired Mac; nil in the demo and before pairing.
    var link: LiveLink?
    /// The demo's Macs are named by these.
    private var demoID = NotificationAnswer.demoMac

    /// The pairing this model was built for, kept so a link that failed to open can be built again.
    private(set) var pairing: PairedMac?

    /// Open incidents on the providers' status pages, read from the Mac's latest state; the demo has none.
    var incidents: [Incident] { link?.state.incidents ?? [] }

    /// The Mac's id, as pushes, deep links and the outbox name it.
    var macID: String { link?.mac.endpoint.macID ?? pairing?.endpoint.macID ?? demoID }

    init(mac: MacConnection, sessions: SessionsStore, requests: RequestsStore, transcripts: TranscriptStore,
         accounts: AccountsStore, history: HistoryStore, isDemo: Bool, paired: Bool, live: MacTools.Live? = nil) {
        self.mac = mac; self.sessions = sessions; self.requests = requests; self.transcripts = transcripts
        self.accounts = accounts; self.history = history; self.isDemo = isDemo; self.paired = paired
        images = ImageStore(isDemo: isDemo)
        tools = MacTools(isDemo ? .demo(.sample(sessions.sessions)) : live.map(MacTools.Mode.live) ?? .unavailable)
        sessions.title = { [weak tools] in tools?.title(for: $0) ?? $0.title }
    }

    static func demo(now: Date = .now) -> AppModel {
        let model = demo(DemoData(now: now), name: "MacBook Pro", id: NotificationAnswer.demoMac, now: now)
        model.mac.route = .wifi
        #if DEBUG
        // `--demo-linux`: the demo host is a Linux box, to see the copy that doesn't say Mac.
        if ProcessInfo.processInfo.arguments.contains("--demo-linux") {
            model.mac.reportedName = "build-box"
            model.mac.kind = .linux
        }
        #endif
        return model
    }

    /// A second demo Mac, for the multi-Mac screens: a few of the first one's sessions on another machine.
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
    /// `--cut-message`: the sync session's latest answer arrives cut, as the Mac sends one over 6,000 characters, and its
    /// rest comes a moment later, or never with `--cut-fails`.
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

    /// An answered request folds into an "Allowed" line where its card was.
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

/// One paired Mac. With one Mac, the Mac never appears as a header anywhere.
@Observable
final class MacConnection: Identifiable {
    nonisolated deinit {}

    enum Offline: Equatable {
        case tailscaleOff, macUnreachable, macAsleep, relayRefused, noNetwork, revoked, keyChanged, incompatible(installed: String?), appOutdated

        /// Revoked and a changed key end the pairing: the whole Sessions tab says so, not a banner.
        var needsPairing: Bool { self == .revoked || self == .keyChanged }

        /// What's sent meanwhile waits and goes once the Mac is back; the others need someone to act first.
        var comesBack: Bool { [.tailscaleOff, .macUnreachable, .macAsleep, .relayRefused, .noNetwork].contains(self) }

        /// Not known to end the pairing, but a moved or re-keyed Mac looks like this too. Not for a Mac that said it's
        /// asleep, or one that only needs updating.
        var offersPairAgain: Bool { self == .tailscaleOff || self == .macUnreachable || self == .relayRefused }
    }

    enum State: Equatable {
        case connecting, live, reconnecting(since: Date), offline(Offline)

        var isOffline: Bool { if case .offline = self { true } else { false } }
    }

    var isOffline: Bool { state.isOffline }

    /// `state` as the screens show it: a drop that's live again within `blip` never shows, so a socket replaced on the
    /// way back from the background doesn't flash "Reconnecting…".
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
    /// What the Mac calls itself, from its pairing and hellos.
    var reportedName: String
    /// The name given it on this iPhone, which wins everywhere the phone shows the Mac.
    var nickname: String?
    var name: String { nickname ?? reportedName }
    /// What kind of computer it is, from its pairing and hellos; a Mac until it says otherwise. Words about it come from `kind`.
    var kind: HostOS = .macos
    var state: State {
        didSet { if state != oldValue { settle() } }
    }
    var lastSeen: Date
    /// nil until the Mac's first `remote.mac` report, so nothing shows a guess.
    var onPower: Bool?
    var battery: Int?
    var memoryUsed: Double?
    var memoryTotal: Double?
    var keepAwake: Bool?
    /// From the path monitor: a VPN interface (Tailscale) is up.
    var vpnUp = true
    var route: Route?

    enum Route: Equatable {
        case wifi, tailscale, relay

        /// Any direct address off the tailnet is one the phone can reach only on the Mac's own network.
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

    /// A path `Paths` still holds says nothing while the events socket is down.
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

    /// Renamed on this iPhone, or back to the Mac's own name with nil or blank; kept per Mac across launches.
    func rename(_ nickname: String?, macID: String, in defaults: UserDefaults = MacNicknames.store) {
        MacNicknames.set(nickname, for: macID, in: defaults)
        let next = MacNicknames.nickname(for: macID, in: defaults)
        if self.nickname != next { self.nickname = next }
    }

    /// Back in front: a drop the app only saw while it was away gets the same minute of "Reconnecting…" as a fresh one,
    /// so Send isn't held off while the link comes back. A pairing that ended, or a Mac that said it's asleep, stays.
    func foregrounded(now: Date = .now) {
        switch state {
        case .offline(.macUnreachable), .offline(.noNetwork): state = .reconnecting(since: now)
        case .offline(.tailscaleOff) where vpnUp: state = .reconnecting(since: now)
        default: break
        }
    }
}

/// Names given to paired Macs on this iPhone, by Mac id, in the App Group so every part of the app reads the same.
enum MacNicknames {
    nonisolated(unsafe) static let store = UserDefaults(suiteName: SharedStorage.appGroup) ?? .standard
    static let key = "mac.nicknames"

    static func nickname(for macID: String, in defaults: UserDefaults = store) -> String? {
        (defaults.dictionary(forKey: key) as? [String: String])?[macID]
    }

    /// Blank or nil goes back to the Mac's own name.
    static func set(_ nickname: String?, for macID: String, in defaults: UserDefaults = store) {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        all[macID] = trimmed?.isEmpty == false ? trimmed : nil
        defaults.set(all, forKey: key)
    }

    /// What the phone calls a Mac it only knows the pairing of.
    static func name(_ reported: String, macID: String, in defaults: UserDefaults = store) -> String {
        nickname(for: macID, in: defaults) ?? reported
    }
}

extension PairedMac {
    /// Its name as this iPhone shows it.
    var displayName: String { MacNicknames.name(endpoint.name, macID: endpoint.macID) }
}
