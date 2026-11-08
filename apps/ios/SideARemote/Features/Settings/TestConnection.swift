import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftUI
import UserNotifications

/// Test Connection on the phone (setup, "Diagnostics"): four plain answers, each naming the first thing wrong. The
/// relay is checked on its own, so a broken relay shows even while a direct path carries everything.
@Observable
final class ConnectionTest {
    nonisolated deinit {}

    enum Outcome: Equatable {
        case waiting, running, passed(String), failed(String, detail: String?), notChecked(String?)
    }

    struct Step: Identifiable, Equatable {
        let id: Int
        let title: String
        var outcome: Outcome = .waiting
    }

    static let reaching = 0, relay = 1, paired = 2, notifications = 3

    private(set) var steps: [Step]
    private(set) var running = false
    /// Nil in the demo, whose Macs have no pairing: its runs are made up and nothing is sent.
    let mac: PairedMac?
    let name: String

    init(mac: PairedMac) {
        self.mac = mac
        name = mac.endpoint.name
        steps = Self.titles
    }

    private init(demo name: String) {
        mac = nil
        self.name = name
        steps = Self.titles
    }

    static func demo(_ name: String) -> ConnectionTest { ConnectionTest(demo: name) }

    private static var titles: [Step] {
        ["Reaching the Mac", "Relay", "Paired and live", "Notifications"].enumerated().map { Step(id: $0.offset + 1, title: $0.element) }
    }

    func run(engine: SyncEngine?) async {
        running = true
        defer {
            running = false
            RemoteLog.log(.app, "test connection\n\(report)")
        }
        for index in steps.indices { steps[index].outcome = .running }
        guard let mac else { return await runDemo() }
        let paths = Paths.shared(for: mac.endpoint, credentials: KeychainCredentials())
        async let relay = paths.checkRelay()

        let path = await paths.retest()
        let client = RemoteClient(endpoint: mac.endpoint, credentials: KeychainCredentials())
        var hello: Result<Hello, Error>
        do { hello = .success(try await client.hello()) } catch { hello = .failure(error) }

        if let path {
            steps[Self.reaching].outcome = .passed(Self.reached(path, mac: name))
        } else {
            // With no path the hello fails at once, with the reason the race found none.
            let error: Error? = if case .failure(let error) = hello { error } else { nil }
            let tailnet = mac.endpoint.addresses.contains { Tailscale.isTailnet($0.host() ?? "") }
            let vpnUp = await Tailscale.vpnUp()
            let tailscaleOff = tailnet && !vpnUp
            steps[Self.reaching].outcome = Self.unreachable(error, mac: name, tailscaleOff: tailscaleOff, hasRelay: mac.endpoint.relay != nil)
        }
        steps[Self.relay].outcome = Self.relayOutcome(await relay, mac: name)

        var live = false
        if path == nil {
            steps[Self.paired].outcome = .notChecked("Needs the Mac reached first")
        } else {
            live = await checkPaired(hello, client: client, engine: engine)
        }
        steps[Self.notifications].outcome = await notificationsOutcome(client: live ? client : nil)
    }

    private func checkPaired(_ hello: Result<Hello, Error>, client: RemoteClient, engine: SyncEngine?) async -> Bool {
        let outcome: Outcome
        switch hello {
        case .failure(is ServerKeyChanged):
            outcome = .failed("\(name) has a new security key, so this iPhone has to pair again.", detail: nil)
        case .failure(let failure as RemoteFailure) where failure.retryable:
            outcome = .failed(failure.error.message, detail: nil)
        case .failure(let error as URLError):
            outcome = .failed("Couldn't connect securely to \(name).", detail: "Error \(error.code.rawValue)")
        case .failure(let error):
            outcome = .failed("Something other than Side A answers at this address.", detail: error.localizedDescription)
        case .success(let hello) where !hello.remoteOn:
            outcome = .failed("Remote is off in Side A on \(name).", detail: nil)
        case .success(let hello):
            do {
                _ = try await client.sessions()
                // The Mac just answered, so an engine waiting out a backoff tries now.
                outcome = await Self.live(engine)
                    ? .passed("Paired as \(mac?.deviceName ?? "this iPhone"), with live updates · Side A \(hello.app)")
                    : .failed("Connected, but live updates are blocked.", detail: "Update Side A on \(name), then try again.")
            } catch let failure as RemoteFailure where failure.status == 401 {
                outcome = .failed("\(name) doesn't accept this iPhone any more.", detail: nil)
            } catch {
                outcome = .failed(error.localizedDescription, detail: nil)
            }
        }
        steps[Self.paired].outcome = outcome
        if case .passed = outcome { return true }
        return false
    }

    /// `client` is nil when the Mac can't be asked.
    private func notificationsOutcome(client: RemoteClient?) async -> Outcome {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default: return .failed("Notifications are off for Side A Remote.", detail: "Turn them on in Settings › Notifications.")
        }
        guard mac?.relayURL != nil else { return .notChecked("Allowed here. \(name) needs the relay to send them.") }
        guard let client else { return .notChecked("Allowed here. \(name) couldn't be asked about its last one.") }
        return await Self.pushStatus(client, mac: name)
    }

    private func runDemo() async {
        try? await Task.sleep(for: .milliseconds(600))
        steps[Self.reaching].outcome = .passed(Self.reached(.direct(URL(string: "https://192.168.1.20:47800")!), mac: name))
        steps[Self.relay].outcome = Self.relayOutcome(.answered, mac: name)
        steps[Self.paired].outcome = .passed("Paired as iPhone, with live updates · Side A 0.5.47")
        steps[Self.notifications].outcome = .passed("\(name) can reach this iPhone")
    }

    static func reached(_ path: Paths.Path, mac: String) -> String {
        switch path {
        case .relay: "Reached \(mac) through the relay"
        case .direct(let url):
            "Reached \(mac) over \(Tailscale.isTailnet(url.host() ?? "") ? "Tailscale" : "Wi\u{2011}Fi") · \(url.host() ?? "")"
        }
    }

    static func unreachable(_ error: Error?, mac: String, tailscaleOff: Bool, hasRelay: Bool) -> Outcome {
        switch error {
        case is ServerKeyChanged:
            .failed("\(mac) has a new security key, so this iPhone has to pair again.", detail: nil)
        case is LocalNetworkDenied:
            .failed("Side A Remote isn't allowed on the local network.", detail: "Turn it on in Settings › Privacy & Security › Local Network.")
        case is RelayRefused:
            .failed(RelayRefused().localizedDescription, detail: nil)
        default:
            .failed("Couldn't reach \(mac).", detail: tailscaleOff ? "Tailscale looks off on this iPhone."
                : hasRelay ? "No address answered, nor did the relay. Is the Mac awake, with Side A open?"
                : "No address answered. Is the Mac awake, with Side A open?")
        }
    }

    static func relayOutcome(_ check: Paths.RelayCheck, mac: String) -> Outcome {
        switch check {
        case .notSetUp: .notChecked("Not set up")
        case .answered: .passed("The relay works: \(mac) is online on it")
        case .macOffline: .failed("\(mac) isn't on the relay.", detail: "Open Side A on the Mac and check that Remote is on.")
        case .refused: .failed(RelayRefused().localizedDescription, detail: nil)
        case .failed(let why): .failed("The relay couldn't reach \(mac).", detail: why)
        }
    }

    /// The engine's events socket is live, or comes up within `within` of being asked to reconnect now.
    static func live(_ engine: SyncEngine?, within: Duration = .seconds(6)) async -> Bool {
        guard let engine else { return false }
        if await engine.state.connection.isLive { return true }
        await engine.reconnectNow()
        let deadline = ContinuousClock.now + within
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            if await engine.state.connection.isLive { return true }
        }
        return false
    }

    /// Asks the Mac for one test notification, whatever else this screen has found.
    func sendTestNotification() async {
        running = true
        defer { running = false }
        steps[Self.notifications].outcome = .running
        guard let mac else {
            try? await Task.sleep(for: .milliseconds(400))
            return steps[Self.notifications].outcome = Self.testNotification(.ok, mac: name)
        }
        let client = RemoteClient(endpoint: mac.endpoint, credentials: KeychainCredentials())
        do {
            steps[Self.notifications].outcome = Self.testNotification(try await client.testPush().relay, mac: name)
        } catch {
            steps[Self.notifications].outcome = .failed((error as? RemoteFailure)?.error.message ?? error.localizedDescription, detail: nil)
        }
    }

    static func testNotification(_ relay: DiagnosticPush.Relay, mac: String) -> Outcome {
        switch relay {
        case .ok: .passed("Test notification sent")
        case .unverified: .failed("This iPhone hasn't confirmed notifications yet.", detail: "Open Side A Remote again in a moment, then try again.")
        case .gone: .failed("Apple says this iPhone's notification token is gone.", detail: "Open Side A Remote once so it registers again.")
        case .retry, .unreachable: .failed("\(mac) couldn't reach the notification relay.", detail: nil)
        default: .failed("The notification relay refused the test.", detail: nil)
        }
    }

    /// `GET /v1/setup`'s push line. "unverified": the relay holds this iPhone's token but the iPhone hasn't confirmed it
    /// yet, so the Mac's pushes go nowhere until it does.
    static func pushStatus(_ client: RemoteClient, mac: String) async -> Outcome {
        guard let push = try? await client.setup().push else { return .notChecked("Allowed here. \(mac) didn't say how its last one went.") }
        guard push.registered else { return .notChecked("Allowed here. This iPhone isn't registered with \(mac) yet.") }
        return switch DiagnosticPush.Relay(rawValue: push.lastResult ?? "ok") {
        case .ok: .passed("\(mac) can reach this iPhone")
        case .unverified: .notChecked("Allowed here. Waiting for this iPhone to confirm notifications.")
        case .gone: .failed("Apple says this iPhone's notification token is gone.", detail: "Open Side A Remote once so it registers again.")
        case .retry, .unreachable: .failed("\(mac) couldn't reach the notification relay.", detail: "It tries again on the next notification.")
        default: .failed("The notification relay refused \(mac)'s last notification.", detail: nil)
        }
    }

    var report: String {
        let info = ClientInfo.current
        let lines = steps.map { step -> String in
            let result: String = switch step.outcome {
            case .passed(let line): "✓ \(line)"
            case .failed(let line, let detail): "✗ \(line)" + (detail.map { " \($0)" } ?? "")
            case .notChecked(let note): "– " + (note ?? "Not checked")
            case .waiting, .running: "– Not checked"
            }
            return "\(step.id). \(step.title): \(result)"
        }
        // The key hash's first 8 characters only; never tokens or content.
        let key = mac.map { " · key \($0.endpoint.serverKeyHash.prefix(8))…" } ?? " · demo"
        return (["Side A Remote \(info.version) (\(info.build)) · \(info.system)", "Mac \(name)\(key)"] + lines).joined(separator: "\n")
    }
}

/// Tests `link`'s Mac with that Mac's own engine, whichever Mac the screen it was opened from shows.
struct TestConnectionView: View {
    private let link: LiveLink?
    @State private var test: ConnectionTest
    @State private var copies = 0

    init(link: LiveLink) {
        self.link = link
        test = ConnectionTest(mac: link.mac)
    }

    init(demo name: String) {
        link = nil
        test = .demo(name)
    }

    var body: some View {
        List {
            Section {
                ForEach(test.steps) { step in
                    StepRow(step: step) {
                        if step.id - 1 == ConnectionTest.notifications, step.outcome != .running {
                            Button("Send Test Notification", systemImage: "bell.badge") { Task { await test.sendTestNotification() } }
                                .font(.subheadline)
                                .buttonStyle(.borderless)
                                .disabled(test.running)
                        }
                    }
                }
            } header: {
                Text(test.name)
            }
            Section {
                Button("Run Again", systemImage: "arrow.clockwise") { Task { await test.run(engine: link?.engine) } }
                Button("Copy Report", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = test.report
                    copies += 1
                }
                ShareLink(item: LogExport(), preview: SharePreview("Side A Remote Logs")) {
                    Label("Share Logs", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(test.running)
        }
        .navigationTitle("Test Connection")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: copies)
        .task { await test.run(engine: link?.engine) }
    }

    private struct StepRow<Action: View>: View {
        let step: ConnectionTest.Step
        @ViewBuilder let action: () -> Action
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                icon.frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    switch step.outcome {
                    case .passed(let line):
                        Text(line)
                    case .failed(let line, let detail):
                        Text(line)
                        if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                    case .notChecked(let note):
                        Text(step.title).foregroundStyle(.secondary)
                        Text(note ?? "Not checked").font(.subheadline).foregroundStyle(.tertiary)
                    case .waiting, .running:
                        Text(step.title).foregroundStyle(.secondary)
                    }
                    action()
                }
            }
            .animation(Motion.smooth(reduceMotion), value: step.outcome)
            .accessibilityElement(children: .contain)
        }

        @ViewBuilder private var icon: some View {
            switch step.outcome {
            case .passed: Image(systemName: "checkmark").foregroundStyle(Color.done).fontWeight(.semibold)
            case .failed: Image(systemName: "xmark").foregroundStyle(Color.destructive).fontWeight(.semibold)
            case .running: ProgressView().controlSize(.small)
            case .waiting, .notChecked: Text("–").foregroundStyle(.tertiary)
            }
        }
    }
}

/// The rolling log, joined into one text file when Share Logs is tapped.
struct LogExport: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { _ in
            guard let file = RemoteLog.export() else { throw CocoaError(.fileNoSuchFile) }
            return SentTransferredFile(file)
        }
    }
}
