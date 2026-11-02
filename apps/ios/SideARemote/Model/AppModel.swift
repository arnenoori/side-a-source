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
    let mac: MacConnection
    let sessions: SessionsStore
    let requests: RequestsStore
    let transcripts: TranscriptStore
    let accounts: AccountsStore
    let history: HistoryStore
    let images: ImageStore
    let tools: MacTools
    /// Fictional data, no network, nothing written outside the app's own container.
    let isDemo: Bool
    var paired: Bool
    /// The connection to the paired Mac; nil in the demo and before pairing.
    private(set) var link: LiveLink?
    /// The demo's Macs are named by these.
    private var demoID = NotificationAnswer.demoMac

    /// The Mac's id, as pushes, deep links and the outbox name it.
    var macID: String { link?.mac.endpoint.macID ?? demoID }

    init(mac: MacConnection, sessions: SessionsStore, requests: RequestsStore, transcripts: TranscriptStore,
         accounts: AccountsStore, history: HistoryStore, isDemo: Bool, paired: Bool) {
        self.mac = mac; self.sessions = sessions; self.requests = requests; self.transcripts = transcripts
        self.accounts = accounts; self.history = history; self.isDemo = isDemo; self.paired = paired
        images = ImageStore(isDemo: isDemo)
        tools = MacTools(demo: isDemo ? .sample(sessions.sessions) : nil)
    }

    static func demo(now: Date = .now) -> AppModel {
        demo(DemoData(now: now), name: "MacBook Pro", now: now)
    }

    /// A second demo Mac, for the multi-Mac screens: a few of the first one's sessions on another machine.
    static func demoSecond(now: Date = .now) -> AppModel {
        let model = demo(DemoData(now: now).second, name: "Mac mini", now: now)
        model.demoID = "demo-2"
        return model
    }

    private static func demo(_ data: DemoData, name: String, now: Date) -> AppModel {
        let requests = RequestsStore(data.requests)
        let sessions = SessionsStore(data.sessions, extras: data.extras)
        let transcripts = TranscriptStore(data.transcripts, earlier: data.earlier)
        let model = AppModel(mac: MacConnection(name: name, state: .live, lastSeen: now),
                             sessions: sessions, requests: requests, transcripts: transcripts,
                             accounts: AccountsStore(data.accounts, autopilot: data.autopilot), history: HistoryStore(data.history),
                             isDemo: true, paired: true)
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
    /// open, and the model stays empty and connecting.
    static func live(_ mac: PairedMac) -> AppModel {
        let model = AppModel(mac: MacConnection(name: mac.endpoint.name, state: .connecting, lastSeen: .now), sessions: SessionsStore([]),
                             requests: RequestsStore([]), transcripts: TranscriptStore([:]), accounts: AccountsStore([]),
                             history: HistoryStore([]), isDemo: false, paired: true)
        model.foldAnswers()
        if let cache = StateCache.load(mac.endpoint.macID) {
            model.restore(cache)
            Launch.mark("sessions from cache", "\(cache.sessions.count) sessions, \(cache.transcripts.count) transcripts")
        }
        if let file = SharedStorage.database, let outbox = try? Outbox(file: file) {
            let link = LiveLink(mac: mac, outbox: outbox)
            model.link = link
            link.attach(model)
            let engine = link.engine
            model.tools.engine = engine
            model.tools.paired = mac
            model.tools.outbox = outbox
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
    enum Offline: Equatable {
        case tailscaleOff, macUnreachable, macAsleep, relayRefused, revoked, keyChanged, incompatible(installed: String?), appOutdated

        /// Revoked and a changed key end the pairing: the whole Sessions tab says so, not a banner.
        var needsPairing: Bool { self == .revoked || self == .keyChanged }

        /// Not known to end the pairing, but a moved or re-keyed Mac looks like this too. Not for a Mac that said it's
        /// asleep, or one that only needs updating.
        var offersPairAgain: Bool { self == .tailscaleOff || self == .macUnreachable || self == .relayRefused }
    }

    enum State: Equatable {
        case connecting, live, reconnecting(since: Date), offline(Offline)
    }

    let id = UUID()
    var name: String
    var state: State
    var lastSeen: Date
    var onPower = true
    var battery: Int?
    var memoryUsed: Double = 21.4
    var memoryTotal: Double = 36
    var keepAwake = true
    /// From the path monitor: a VPN interface (Tailscale) is up.
    var vpnUp = true

    init(name: String, state: State, lastSeen: Date) { self.name = name; self.state = state; self.lastSeen = lastSeen }
}
