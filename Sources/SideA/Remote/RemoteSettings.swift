import AppKit
import SideACore
import SwiftUI

/// Settings > iPhone, in the order someone sets it up: the switch, their iPhones, what reaches the iPhone, and how
/// the Mac is reached, with the rarely used tools last.
struct RemoteSettings: View {
    @Bindable var store: AccountStore
    @State private var revoking: RemoteDevice?
    @State private var renewingKey = false
    @AppStorage(RemoteController.lanKey) private var lan = false
    @AppStorage(RemoteController.anywhereKey) private var anywhere = true
    @AppStorage(Island.onKey) private var islandOn = false

    private var remote: RemoteController { store.remote }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { remote.on }, set: { remote.setEnabled($0) })) {
                    Text("Side A Remote")
                    if let detail = switchDetail { Text(detail) }
                }
                .disabled(!remote.available)
            }
            if remote.on {
                phones
                onPhone
                connection
                tools
            }
        }
        .formStyle(.grouped)
        .task {
            // Re-read while the tab is open, so a Tailscale that comes up turns the switch on without a click elsewhere.
            while !Task.isCancelled {
                remote.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .sheet(isPresented: Binding(get: { remote.pairing != nil }, set: { if !$0 { remote.endPairing() } })) {
            PairingSheet(remote: remote)
        }
        .confirmationDialog(revoking.map { "Revoke \($0.name)?" } ?? "", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button("Revoke", role: .destructive) { if let device = revoking { remote.revoke(device.id) }; revoking = nil }
        } message: {
            Text("It disconnects now and has to pair again.")
        }
        .confirmationDialog("Make a new security key?", isPresented: $renewingKey) {
            Button("Make New Key", role: .destructive) { remote.makeNewKey() }
        } message: {
            Text("Every iPhone has to pair again.")
        }
    }

    private var switchDetail: String? {
        if !remote.available { return store.isDemo ? "The demo doesn't serve Remote." : "Only Side A in Applications can serve Remote." }
        return remote.on ? nil : "Answer requests from your iPhone."
    }

    /// What the iPhone gets: requests to answer, messages it can send, and a Mac that stays awake to answer them.
    @ViewBuilder private var onPhone: some View {
        Section("On iPhone") {
            // The notch and the iPhone share these hooks, so with the notch on they're set once, in Notifications.
            if islandOn {
                LabeledContent {
                    Button("Show") { store.settingsTab = .notifications }
                } label: {
                    Text("Claude Code and Codex requests")
                    Text("Set with the notch, in Notifications.")
                }
            } else {
                Toggle("Claude Code requests", isOn: hook(.claude))
                Toggle(isOn: hook(.codex)) {
                    Text("Codex requests")
                    Text("Approve the hook once with /hooks in Codex.")
                }
            }
            Toggle("Messages to Claude in a terminal", isOn: Binding(get: { remote.inbox.installed }, set: { value in Task { await remote.inbox.set(value) } }))
                .disabled(store.island.installed[.claude] != true)
                .task { await remote.inbox.refresh() }
            // An iPhone can't reach a Mac that's asleep; the switch itself lives in General.
            if !store.keepAwake.settings.enabled {
                LabeledContent {
                    Button("Turn On") { store.keepAwake.setEnabled(true) }
                } label: {
                    Text("This Mac can fall asleep")
                    Text("Your iPhone can't reach it then. Keep awake is in General.")
                }
            }
        }
    }

    @ViewBuilder private var tools: some View {
        Section {
            HStack {
                Button("Copy Diagnostics") { copyDiagnostics() }
                Spacer()
                Button("Make New Key…") { renewingKey = true }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let error = remote.error, error != RemoteController.keyWaiting { Text(error).foregroundStyle(.red) }
                Text(remote.hello(paired: nil).versionLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var phones: some View {
        Section("iPhones") {
            if remote.devices.unreadable != nil {
                LabeledContent {
                    Button("Pair Again…") { remote.resetDevices(); remote.beginPairing() }
                } label: {
                    Label("Paired devices couldn't be read.", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            } else if remote.devices.devices.isEmpty {
                Text("No iPhone yet").foregroundStyle(.secondary)
            }
            ForEach(remote.devices.devices) { device in
                LabeledContent {
                    Button("Revoke") { revoking = device }
                        .accessibilityLabel("Revoke \(device.name)")
                } label: {
                    Text(device.name)
                    Text(seen(device))
                }
            }
            Button("Pair iPhone…") { remote.beginPairing() }
                .disabled((!remote.listening.values.contains(.ready) && remote.tunnel == nil) || remote.devices.unreadable != nil)
        }
    }

    private func seen(_ device: RemoteDevice) -> String {
        if remote.connected[device.id, default: 0] > 0 { return "Connected now" }
        guard let last = device.lastSeen else { return "Never connected" }
        return "Last seen " + Date(timeIntervalSince1970: last).formatted(.relative(presentation: .named))
    }

    @ViewBuilder private var connection: some View {
        Section {
            if remote.firewall?.blocksPhones == true {
                LabeledContent {
                    Button("Open Firewall Settings") { NSWorkspace.shared.open(Firewall.settings) }
                } label: {
                    statusLabel(Text("macOS Firewall is blocking iPhones"), "exclamationmark.triangle.fill", .yellow)
                }
            }
            tailscaleRow
            listenerRow
            if remote.tailscale?.state == .ready, remote.tailscale?.phones.isEmpty == true {
                Label("Install Tailscale on your iPhone and sign in with the same account.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(get: { lan }, set: { remote.setLAN($0) })) {
                Text("Also on this Wi-Fi")
                if lan { Text(remote.boundLAN.first.map { RemoteController.hostPort($0, remote.port) } ?? "No Wi-Fi address yet") }
            }
            if remote.relayURL != nil {
                Toggle(isOn: Binding(get: { anywhere }, set: { remote.setAnywhere($0) })) {
                    Text("Reach this Mac from anywhere")
                    Text("Through Side A's relay, end to end encrypted.")
                }
                if anywhere, remote.on { tunnelRow }
            }
        } header: {
            Text("Connection")
        }
    }

    @ViewBuilder private var tunnelRow: some View {
        switch remote.tunnelStatus {
        case .off: statusLabel(Text("Starts when an iPhone is paired"), "clock", .secondary)
        case .connecting: statusLabel(Text("Connecting to the relay…"), "ellipsis.circle", .secondary)
        case .connected: statusLabel(Text("Connected to the relay"), "checkmark.circle.fill", .green)
        case .waiting(let why): statusLabel(Text(why), "exclamationmark.triangle.fill", .yellow)
        }
    }

    @ViewBuilder private var tailscaleRow: some View {
        let status = remote.tailscale
        switch status?.state {
        case nil:
            Label("Checking Tailscale…", systemImage: "ellipsis.circle").foregroundStyle(.secondary)
        case .notInstalled:
            fix("Tailscale isn't installed", "Get Tailscale", URL(string: "https://tailscale.com/download/mac")!)
        case .stopped:
            fix("Tailscale is off", "Open Tailscale", URL(fileURLWithPath: "/Applications/Tailscale.app"))
        case .needsLogin:
            fix("Sign in to Tailscale", "Open Tailscale", URL(fileURLWithPath: "/Applications/Tailscale.app"))
        case .noAddress:
            statusLabel(Text("Tailscale has no address yet"), "clock", .secondary)
        case .ready:
            LabeledContent {
                // The address a phone reaches; on Wi-Fi alone it shows under the Wi-Fi switch instead.
                if let address = remote.boundTailnet.first, remote.listening.values.contains(.ready) {
                    Text(RemoteController.hostPort(address, remote.port)).monospacedDigit().textSelection(.enabled)
                }
            } label: {
                statusLabel(Text("Tailscale"), "checkmark.circle.fill", .green)
                if let login = status?.login { Text(login) }
            }
        }
    }

    /// Only while it isn't listening: once it is, the addresses show on the Tailscale and Wi-Fi rows.
    @ViewBuilder private var listenerRow: some View {
        let states = remote.listening
        if let failure = states.values.compactMap({ if case .failed(let why) = $0 { why } else { nil } }).first {
            statusLabel(Text(failure == "Port in use" ? "Port \(String(remote.port)) is in use by another app" : "Side A couldn't listen: \(failure)"),
                   "exclamationmark.triangle.fill", .yellow)
        } else if remote.endpoints == nil {
            statusLabel(Text(lan ? "Waiting for a network" : "Turn on Wi-Fi below, or Tailscale"), "clock", .secondary)
        } else if remote.error == RemoteController.keyWaiting {
            LabeledContent {} label: {
                statusLabel(Text("Waiting for keychain access"), "lock", .secondary)
                Text("Look for a macOS dialog asking about Side A.")
            }
        } else if !states.values.contains(.ready) {
            statusLabel(Text("Starting…"), "ellipsis.circle", .secondary)
        }
    }

    /// A status line as System Settings draws one: the symbol carries the color, the words stay primary.
    private func statusLabel(_ text: Text, _ symbol: String, _ color: Color) -> some View {
        Label { text } icon: { Image(systemName: symbol).foregroundStyle(color) }
    }

    private func fix(_ line: String, _ button: String, _ url: URL) -> some View {
        LabeledContent {
            Button(button + (url.isFileURL ? "" : " ↗")) { NSWorkspace.shared.open(url) }
        } label: {
            statusLabel(Text(line), "exclamationmark.circle", .secondary)
        }
    }

    private func hook(_ agent: IslandAgent) -> Binding<Bool> {
        Binding(get: { store.island.installed[agent] == true },
                set: { value in Task { await store.setIsland(agent, value ? "on" : "off") } })
    }

    /// No tokens, hashes or keys: only what helps tell why a phone can't connect.
    private func copyDiagnostics() {
        var lines = ["Side A Remote · \(remote.on ? "on" : "off") · port \(remote.port) · epoch \(remote.epoch) · \(remote.hello(paired: nil).versionLine)"]
        if let status = remote.tailscale {
            lines.append("Tailscale \(status.version ?? "?") · \(status.state) · addresses \(status.addresses.joined(separator: ", ")) · MagicDNS \(status.dnsName != nil ? "on" : "off") · iPhones \(status.phones.count)")
        }
        lines.append("Listeners: " + remote.listening.map { "\($0.key) \($0.value)" }.sorted().joined(separator: "; "))
        lines.append("Relay tunnel: \(remote.tunnel == nil ? "off" : "\(remote.tunnelStatus)") · streams \(remote.tunnel?.streams ?? 0)")
        lines.append("Devices: \(remote.devices.devices.count) · connected \(remote.connected.values.reduce(0, +)) · key \(remote.keyID?.prefix(8) ?? "none")")
        lines.append("Key access: \(remote.keyAccess)")
        lines.append("Firewall: \(remote.firewall.map { "\($0)" } ?? "unknown")")
        lines += remote.server?.recentErrors ?? []
        lines.append("Log (~/Library/Logs/SideA/remote.log), last \(RemoteLog.kept) lines:")
        lines += RemoteLog.shared.recent
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

/// Pair iPhone: one fixed-size sheet whose phases crossfade in place, so the window never jumps. The QR is the hero,
/// then the six digits, then a check. QR only: typing the code would skip the key pin the QR carries.
struct PairingSheet: View {
    var remote: RemoteController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 420, height: 520)

    var body: some View {
        ZStack {
            if let session = remote.pairing {
                phase(session)
                    .id(Self.key(session.phase))
                    .transition(.opacity)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: remote.pairing.map { Self.key($0.phase) })
    }

    private static func key(_ phase: PairingSession.Phase) -> String {
        switch phase {
        case .code: "code"
        case .confirm(let attempt): "confirm-\(attempt.id)"
        case .paired: "paired"
        case .stopped(let reason): "stopped-\(reason)"
        }
    }

    @ViewBuilder private func phase(_ session: PairingSession) -> some View {
        switch session.phase {
        case .code: code(session)
        case .confirm(let attempt): confirm(session, attempt)
        case .paired(let name): Paired(name: name) { remote.endPairing() }
        case .stopped(let reason):
            frame {
                Image(systemName: Self.symbol(reason))
                    .font(.system(size: 64, weight: .regular))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                Text(reason).font(.title2.weight(.semibold))
            } buttons: {
                Button("Close") { remote.endPairing() }.keyboardShortcut(.cancelAction).controlSize(.large).buttonStyle(.borderless)
                Button("Start Again") { session.restart() }.keyboardShortcut(.defaultAction).controlSize(.large).buttonStyle(.borderedProminent)
            }
        }
    }

    /// The content centred, the buttons on one row along the bottom, in the same place in every phase.
    private func frame(@ViewBuilder _ content: () -> some View, @ViewBuilder buttons: () -> some View) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 20) { content() }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            // A little above centre, as the eye expects; the buttons hold the bottom.
            Spacer(minLength: 0)
            Spacer(minLength: 0).frame(maxHeight: 24)
            HStack(spacing: 12) { buttons() }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
    }

    @ViewBuilder private func code(_ session: PairingSession) -> some View {
        frame {
            Text("Scan with your iPhone").font(.title2.weight(.semibold))
            QRCard(link: remote.qrLink, icon: NSApp?.applicationIconImage)
        } buttons: {
            // Codes renew on their own; how long this one has shows only once it's short.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(session.code.expiresAt - context.date.timeIntervalSince1970))
                Text(left <= 60 ? "New code in \(left) s" : " ")
                    .monospacedDigit().font(.callout).foregroundStyle(.secondary)
                    .contentTransition(.numericText(countsDown: true))
            }
            Spacer()
            Button("Cancel") { remote.endPairing() }.keyboardShortcut(.cancelAction).controlSize(.large)
        }
    }

    @ViewBuilder private func confirm(_ session: PairingSession, _ attempt: PairingSession.Attempt) -> some View {
        if attempt.keyMatches {
            frame {
                Image(systemName: "iphone.gen3").font(.system(size: 56)).foregroundStyle(.tint).symbolRenderingMode(.hierarchical)
                Text("Pair “\(attempt.request.device.name)”?").font(.title2.weight(.semibold)).lineLimit(2)
                Digits(code: attempt.comparison)
            } buttons: {
                Button("Don’t Match") { session.decide(.mismatch) }.controlSize(.large)
                // Prominent, but never the default: Return mustn't approve a pairing; the digits are read, then clicked.
                Button("Pair") { session.decide(.pair) }.controlSize(.large).buttonStyle(.borderedProminent)
            }
        } else {
            frame {
                Image(systemName: "exclamationmark.shield.fill").font(.system(size: 64)).foregroundStyle(.orange).symbolRenderingMode(.hierarchical)
                Text("Different Security Key").font(.title2.weight(.semibold))
            } buttons: {
                Button("Close") { session.decide(.mismatch); remote.endPairing() }.keyboardShortcut(.defaultAction).controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Each way a pairing stops, as a symbol; its title says the rest.
    static func symbol(_ reason: String) -> String {
        switch reason {
        case "Code Expired": "clock.badge.xmark"
        case "Too Many Wrong Codes": "lock.trianglebadge.exclamationmark"
        case "Two Devices Used This Code": "iphone.gen3.badge.exclamationmark"
        case "Codes Didn’t Match", "Codes Didn't Match": "xmark.shield"
        case "Nobody Clicked Pair in Time": "hourglass"
        case "Pairing Cancelled": "xmark.circle"
        default: "exclamationmark.circle"
        }
    }
}

/// The QR on a white card whatever the appearance, so every camera reads it, with the app's icon in its centre
/// (error correction H keeps it readable under the icon).
private struct QRCard: View {
    let link: String?
    let icon: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.black.opacity(0.06)))
            if let link, let image = PairingSession.qr(link, correction: "H") {
                Image(decorative: image, scale: 2)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(.white))
                }
            } else {
                ProgressView()
            }
        }
        .frame(width: 272, height: 272)
        .accessibilityElement()
        .accessibilityLabel("Pairing QR code")
    }
}

/// The comparison code as two groups of three in tiles, big enough to check from across a desk.
private struct Digits: View {
    let code: String

    var body: some View {
        let digits = code.filter(\.isNumber).map(String.init)
        HStack(spacing: 14) {
            ForEach([0, 1], id: \.self) { group in
                HStack(spacing: 6) {
                    ForEach(Array(digits.dropFirst(group * 3).prefix(3).enumerated()), id: \.offset) { _, digit in
                        Text(digit)
                            .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
                            .frame(width: 46, height: 64)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary))
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(digits.joined(separator: " "))
    }
}

/// A check that springs in, then the sheet closes itself.
private struct Paired: View {
    let name: String
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 96))
                .foregroundStyle(.white, .green)
                .symbolEffect(.bounce, value: shown)
                .scaleEffect(shown || reduceMotion ? 1 : 0.6)
                .opacity(shown || reduceMotion ? 1 : 0)
            Text("Paired with \(name)").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if reduceMotion { shown = true } else { withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { shown = true } }
        }
        .task {
            try? await Task.sleep(for: .seconds(1.6))
            close()
        }
    }
}
