import ActivityKit
import Network
import os
import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftUI
import UserNotifications

/// Test Connection on the phone (setup, "Diagnostics"): walks from this iPhone out to the Mac, stops
/// at the first failing step and says what to do. Steps after a failure show "Not checked".
@Observable
final class ConnectionTest {
    enum Outcome: Equatable {
        case waiting, running, passed(String), failed(String, detail: String?), notChecked(String?)
    }

    struct Step: Identifiable, Equatable {
        let id: Int
        let title: String
        var outcome: Outcome = .waiting
    }

    private(set) var steps: [Step]
    private(set) var running = false
    let mac: PairedMac

    init(mac: PairedMac) {
        self.mac = mac
        steps = ["Tailscale on this iPhone", "Reaching the Mac", "Security key", "Side A", "This iPhone", "Live updates",
                 "Notifications on this iPhone", "Notifications from the Mac", "Test notification", "Live Activities"]
            .enumerated().map { Step(id: $0.offset + 1, title: $0.element) }
    }

    func run(engine: SyncEngine?) async {
        running = true
        defer {
            running = false
            RemoteLog.log(.app, "test connection\n\(report)")
        }
        for index in steps.indices { steps[index].outcome = .waiting }
        let name = mac.endpoint.name
        // The path the app is using now, raced afresh if there's none: an address, or the relay.
        let paths = Paths.shared(for: mac.endpoint, credentials: KeychainCredentials())
        let path = await paths.path()
        let viaRelay = path == .relay
        var address = await engine?.state.address ?? mac.endpoint.baseURL
        if case .direct(let url)? = path { address = url }
        let client = RemoteClient(endpoint: mac.endpoint, credentials: KeychainCredentials())

        // 1 · Tailscale is only a hint: an on-demand VPN or a Wi-Fi address can work without it showing.
        let tailnet = Tailscale.isTailnet(address.host() ?? "")
        let vpnUp = await Tailscale.vpnUp()
        steps[0].outcome = viaRelay ? .passed("Not needed: via relay")
            : !tailnet ? .passed("Not needed for \(address.host() ?? "this address")")
            : vpnUp ? .passed("Tailscale is on") : .notChecked("No VPN showing on this iPhone")

        // 2 · TCP connect, 5 s; through the relay, the hello below is the test.
        if viaRelay {
            steps[1].outcome = .passed("Reached \(name) · via relay")
        } else if path == nil {
            steps[1].outcome = .failed("Couldn't reach \(name).", detail: "No address answered, and the relay couldn't reach it either.")
            return skipRest(after: 1)
        } else if !(await check(1, {
            switch await Self.connect(to: address) {
            case .success(let ms):
                .passed("Reached \(name) in \(ms) ms · \(address.host() ?? "")")
            case .failure(let refused):
                refused ? .failed("Open Side A on \(name).", detail: nil)
                    : .failed("Couldn't reach \(name).", detail: tailnet && !vpnUp ? "Tailscale looks off on this iPhone." : nil)
            }
        })) { return skipRest(after: 1) }

        // 3, 4 · pinned TLS, then hello
        var hello: Hello?
        do {
            hello = try await client.hello()
            steps[2].outcome = .passed("Security key matches the one from pairing")
        } catch is ServerKeyChanged {
            steps[2].outcome = .failed("\(name) has a new security key, so this iPhone has to pair again.", detail: nil)
            return skipRest(after: 2)
        } catch let error as URLError {
            // TLS never finished, so the key wasn't checked.
            steps[2].outcome = .failed("Couldn't connect securely to \(name).", detail: "Error \(error.code.rawValue)")
            return skipRest(after: 2)
        } catch let failure as RemoteFailure where failure.retryable {
            // Side A answered, and isn't ready for this iPhone yet.
            steps[2].outcome = .passed("Security key matches the one from pairing")
            steps[3].outcome = .failed(failure.error.message, detail: nil)
            return skipRest(after: 3)
        } catch {
            // TLS finished with the pinned key; what answered isn't Side A.
            steps[2].outcome = .passed("Security key matches the one from pairing")
            steps[3].outcome = .failed("Something other than Side A answers at this address.", detail: error.localizedDescription)
            return skipRest(after: 3)
        }
        if let hello {
            steps[3].outcome = hello.remoteOn
                ? .passed("Side A \(hello.app) · protocol \(hello.protocolVersion) · Remote on")
                : .failed("Remote is off in Side A on \(name).", detail: nil)
            guard hello.remoteOn else { return skipRest(after: 3) }
        }

        // 5 · the token
        guard await check(4, {
            do {
                _ = try await client.sessions()
                return .passed("Paired as \(mac.deviceName)")
            } catch let failure as RemoteFailure where failure.status == 401 {
                return .failed("\(name) doesn't accept this iPhone any more.", detail: nil)
            } catch {
                return .failed(error.localizedDescription, detail: nil)
            }
        }) else { return skipRest(after: 4) }

        // 6 · the events socket, as the engine sees it
        guard await check(5, {
            await engine?.state.connection.isLive == true ? .passed("Live updates connected")
                : .failed("Connected, but live updates are blocked.", detail: "Update Side A on \(name), then try again.")
        }) else { return skipRest(after: 5) }

        // 7 · notifications here
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            steps[6].outcome = .passed(settings.timeSensitiveSetting == .enabled ? "Allowed · Time Sensitive on" : "Allowed")
        default:
            steps[6].outcome = .failed("Notifications are off for Side A Remote.", detail: nil)
        }

        // 8 · what the Mac's last push to this iPhone met; 9 waits for push registration (M2)
        steps[7].outcome = mac.relayURL == nil ? .notChecked("Notifications need the Mac's relay")
            : await Self.pushStatus(client, mac: name)
        steps[8].outcome = .notChecked("Not tested")

        // 10 · informational
        steps[9].outcome = ActivityAuthorizationInfo().areActivitiesEnabled ? .passed("Live Activities on")
            : .notChecked("Live Activities are off for Side A Remote.")
    }

    /// Asks the Mac for one test notification, whatever else this screen has found.
    func sendTestNotification() async {
        running = true
        defer { running = false }
        steps[8].outcome = .running
        let client = RemoteClient(endpoint: mac.endpoint, credentials: KeychainCredentials())
        do {
            steps[8].outcome = Self.testNotification(try await client.testPush().relay, mac: mac.endpoint.name)
        } catch {
            steps[8].outcome = .failed((error as? RemoteFailure)?.error.message ?? error.localizedDescription, detail: nil)
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

    /// `GET /v1/setup`'s push line as a step. "unverified": the relay holds this iPhone's token but the
    /// iPhone hasn't confirmed it yet, so the Mac's pushes go nowhere until it does.
    static func pushStatus(_ client: RemoteClient, mac: String) async -> Outcome {
        guard let push = try? await client.setup().push else { return .notChecked("\(mac) didn't say") }
        guard push.registered else { return .notChecked("This iPhone isn't registered for notifications yet") }
        return switch DiagnosticPush.Relay(rawValue: push.lastResult ?? "ok") {
        case .ok: .passed("\(mac) can reach this iPhone")
        case .unverified: .notChecked("Waiting for this iPhone to confirm notifications")
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
            case .notChecked(let note): "– Not checked" + (note.map { " (\($0))" } ?? "")
            case .waiting, .running: "– Not checked"
            }
            return "\(step.id). \(step.title): \(result)"
        }
        // The key hash's first 8 characters only; never tokens or content.
        return (["Side A Remote \(info.version) (\(info.build)) · \(info.system)",
                 "Mac \(mac.endpoint.name) · key \(mac.endpoint.serverKeyHash.prefix(8))…"] + lines).joined(separator: "\n")
    }

    private func check(_ index: Int, _ body: () async -> Outcome) async -> Bool {
        steps[index].outcome = .running
        let outcome = await body()
        steps[index].outcome = outcome
        if case .failed = outcome { return false }
        return true
    }

    private func skipRest(after index: Int) {
        for later in steps.indices where later > index { steps[later].outcome = .notChecked(nil) }
    }

    enum Connect { case success(Int), failure(refused: Bool) }

    /// A plain TCP connect, timed.
    private static func connect(to url: URL) async -> Connect {
        guard let host = url.host(), let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 47800)) else { return .failure(refused: false) }
        let start = Date.now
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let result: Connect = await withCheckedContinuation { continuation in
            let done = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Connect) -> Void = { result in
                guard done.withLock({ finished in defer { finished = true }; return !finished }) else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(Int(Date.now.timeIntervalSince(start) * 1000)))
                case .failed(let error), .waiting(let error):
                    if case .posix(let code) = error, code == .ECONNREFUSED { finish(.failure(refused: true)) }
                    else if case .failed = state { finish(.failure(refused: false)) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(.failure(refused: false)) }
        }
        return result
    }
}

struct TestConnectionView: View {
    @Environment(AppModel.self) private var model
    @State private var test: ConnectionTest
    @State private var copies = 0

    init(mac: PairedMac) { test = ConnectionTest(mac: mac) }

    var body: some View {
        List {
            Section {
                ForEach(test.steps) { StepRow(step: $0) }
            } header: {
                Text(test.mac.endpoint.name)
            }
            Section {
                Button("Send Test Notification", systemImage: "bell.badge") { Task { await test.sendTestNotification() } }
                Button("Run Again", systemImage: "arrow.clockwise") { Task { await test.run(engine: model.link?.engine) } }
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
        .task { await test.run(engine: model.link?.engine) }
    }

    private struct StepRow: View {
        let step: ConnectionTest.Step
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
                }
            }
            .animation(Motion.smooth(reduceMotion), value: step.outcome)
            .accessibilityElement(children: .combine)
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
