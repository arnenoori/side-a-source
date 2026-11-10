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
        return nil
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
                if let error = remote.error, error != remote.devices.unreadable { Text(error).foregroundStyle(.red) }
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
            }
            ForEach(remote.devices.devices) { device in
                LabeledContent {
                    Button("Revoke") { revoking = device }
                        .accessibilityLabel("Revoke \(device.name)")
                } label: {
                    Label {
                        Text(device.name)
                        Text(seen(device))
                    } icon: {
                        Image(systemName: "iphone.gen3")
                            .foregroundStyle(remote.connected[device.id, default: 0] > 0 ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    }
                }
            }
            pairRow
        }
    }

    /// Pair iPhone… when a phone could reach the sheet; otherwise what's in the way, with the fix beside it.
    @ViewBuilder private var pairRow: some View {
        let none = remote.devices.devices.isEmpty
        switch remote.pairReadiness {
        case .ready:
            LabeledContent {
                Button("Pair iPhone…") { remote.beginPairing() }
                    .buttonStyle(.borderedProminent)
            } label: {
                if none { statusLabel(Text("No iPhone yet"), "iphone.gen3", .secondary).foregroundStyle(.secondary) }
            }
        case .starting:
            LabeledContent {
                ProgressView().controlSize(.small).frame(height: 22)
            } label: {
                statusLabel(Text("Starting Remote…"), "iphone.gen3", .secondary).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .keyWaiting:
            statusLabel(Text("Click Allow in the macOS keychain dialog"), "lock.fill", .secondary)
        case .keyBroken:
            LabeledContent {
                Button("Make New Key…") { renewingKey = true }
            } label: {
                statusLabel(Text("Side A can't use its security key"), "exclamationmark.triangle.fill", .yellow)
            }
        case .noNetwork:
            LabeledContent {
                if !lan { Button("Use Wi-Fi") { remote.setLAN(true) } }
            } label: {
                statusLabel(Text(lan ? "Connect to Wi-Fi or Tailscale" : "Turn on Wi-Fi or Tailscale"), "wifi.slash", .secondary)
            }
        case .cantListen(let why):
            statusLabel(Text(why), "exclamationmark.triangle.fill", .yellow)
        case .devicesUnreadable:
            EmptyView()
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
        case .off: EmptyView()
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

    /// An address that failed while another serves; anything that stops pairing shows with Pair iPhone instead.
    @ViewBuilder private var listenerRow: some View {
        if remote.pairReadiness == .ready,
           let failure = remote.listening.values.compactMap({ if case .failed(let why) = $0 { why } else { nil } }).first {
            statusLabel(Text(failure == RemoteServer.portInUse ? "Port \(String(remote.port)) is in use by another app" : "Side A couldn't listen: \(failure)"),
                   "exclamationmark.triangle.fill", .yellow)
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
/// then the six digits, then the iPhone turning into a check. QR only: typing the code would skip the key pin the QR carries.
struct PairingSheet: View {
    var remote: RemoteController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 440, height: 540)

    var body: some View {
        let key = remote.pairing.map { Self.key($0.phase) }
        ZStack {
            if let session = remote.pairing {
                phase(session)
                    .id(Self.key(session.phase))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35), value: key)
        .onChange(of: key) {
            if let text = remote.pairing.flatMap({ Self.announcement($0.phase) }) { AccessibilityNotification.Announcement(text).post() }
        }
    }

    /// Pairing and paired share one key, so the iPhone turns into the check instead of crossfading.
    private static func key(_ phase: PairingSession.Phase) -> String {
        switch phase {
        case .code: "code"
        case .confirm(let attempt): "confirm-\(attempt.id)"
        case .pairing, .paired: "done"
        case .stopped(let reason): "stopped-\(reason)"
        }
    }

    static func announcement(_ phase: PairingSession.Phase) -> String? {
        switch phase {
        case .code, .pairing: nil
        case .confirm(let attempt) where attempt.keyMatches:
            "Pair \(attempt.request.device.name)? Check that your iPhone shows \(attempt.comparison.filter(\.isNumber).map(String.init).joined(separator: " "))."
        case .confirm: "Different security key."
        case .paired(let name): "Paired with \(name)."
        case .stopped(let reason): reason.rawValue
        }
    }

    @ViewBuilder private func phase(_ session: PairingSession) -> some View {
        switch session.phase {
        case .code: code(session)
        case .confirm(let attempt): confirm(session, attempt)
        case .pairing(let attempt): Done(name: attempt.request.device.name, paired: false) { remote.endPairing() }
        case .paired(let name): Done(name: name, paired: true) { remote.endPairing() }
        case .stopped(let reason):
            frame {
                Hero(symbol: Self.symbol(reason), color: Self.warns(reason) ? .orange : .secondary)
                heading(reason.rawValue, Self.advice(reason))
            } buttons: {
                Spacer()
                Button("Close") { remote.endPairing() }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button("Start Again") { session.restart() }.keyboardShortcut(.defaultAction).controlSize(.large).buttonStyle(.borderedProminent)
            }
        }
    }

    /// The content a little above centre, the buttons along the bottom, in the same place in every phase.
    private func frame(@ViewBuilder _ content: () -> some View, @ViewBuilder buttons: () -> some View) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 22) { content() }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            Spacer(minLength: 0).frame(maxHeight: 20)
            HStack(spacing: 10) { buttons() }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }

    private func heading(_ title: String, _ detail: String?) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.title2.weight(.semibold)).lineLimit(2)
            if let detail { Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    @ViewBuilder private func code(_ session: PairingSession) -> some View {
        frame {
            heading("Scan with your iPhone", "Use the Camera or Side A Remote.")
            QRCard(link: remote.qrLink, icon: NSApp?.applicationIconImage)
        } buttons: {
            Spacer()
            Button("Cancel") { remote.endPairing() }.keyboardShortcut(.cancelAction).controlSize(.large)
        }
    }

    @ViewBuilder private func confirm(_ session: PairingSession, _ attempt: PairingSession.Attempt) -> some View {
        if attempt.keyMatches {
            frame {
                Hero(symbol: "iphone.gen3", color: .accentColor)
                heading("Pair “\(attempt.request.device.name)”?", "Check that your iPhone shows the same code.")
                Digits(code: attempt.comparison)
            } buttons: {
                Button("Don’t Match") { session.decide(.mismatch) }.controlSize(.large)
                Spacer()
                Escape { remote.endPairing() }
                // Prominent, but never the default: Return mustn't approve a pairing; the digits are read, then clicked.
                Button("Pair") { session.decide(.pair) }.controlSize(.large).buttonStyle(.borderedProminent)
                    .accessibilityLabel("Pair \(attempt.request.device.name)")
            }
        } else {
            frame {
                Hero(symbol: "exclamationmark.shield.fill", color: .orange)
                heading("Different Security Key", "Your iPhone reached something other than this Mac. Try another network.")
            } buttons: {
                Spacer()
                Button("Close") { session.decide(.mismatch); remote.endPairing() }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button("Start Again") { session.decide(.mismatch); session.restart() }.keyboardShortcut(.defaultAction).controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    static func symbol(_ reason: PairingSession.Stop) -> String {
        switch reason {
        case .expired: "clock.badge.xmark"
        case .wrongCodes: "lock.trianglebadge.exclamationmark"
        case .twoDevices: "iphone.gen3.badge.exclamationmark"
        case .mismatch: "xmark.shield"
        case .timeout: "hourglass"
        case .cancelled: "xmark.circle"
        case .unsaved: "exclamationmark.triangle"
        }
    }

    /// Stops that may mean someone else tried to pair.
    static func warns(_ reason: PairingSession.Stop) -> Bool { [.wrongCodes, .twoDevices, .mismatch].contains(reason) }

    /// Only where Start Again alone wouldn't be enough.
    static func advice(_ reason: PairingSession.Stop) -> String? {
        switch reason {
        case .twoDevices: "Scan with one iPhone at a time."
        case .mismatch: "Pair only when both show the same code."
        default: nil
        }
    }
}

/// Escape for a phase whose visible buttons mustn't take it.
private struct Escape: View {
    let action: () -> Void

    var body: some View {
        Button("Cancel", action: action)
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

/// A phase's symbol, bouncing once as it arrives.
private struct Hero: View {
    let symbol: String
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 60))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .symbolEffect(.bounce, value: arrived)
            .frame(height: 72)
            .accessibilityHidden(true)
            .onAppear { if !reduceMotion { arrived = true } }
    }
}

/// The QR on a white card whatever the appearance, so every camera reads it, drawn at a whole number of pixels per
/// module so no edge blurs, with the app's icon in its centre (error correction H keeps it readable under the icon).
private struct QRCard: View {
    let link: String?
    let icon: NSImage?
    @Environment(\.displayScale) private var scale

    static let side: CGFloat = 292
    static let most: CGFloat = 252

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                .shadow(color: .black.opacity(0.12), radius: 22, y: 8)
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.black.opacity(0.07)))
            if let link, let image = Self.image(link, scale: scale) {
                ZStack {
                    Image(decorative: image, scale: scale).interpolation(.none)
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 54, height: 54)
                            .padding(5)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white))
                    }
                }
                .id(link)
                .transition(.opacity)
            } else {
                Label("Connect this Mac to Wi-Fi or Tailscale", systemImage: "wifi.slash")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.black.opacity(0.5))
                    .padding(24)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .animation(.easeInOut(duration: 0.3), value: link)
        .accessibilityElement()
        .accessibilityLabel("Pairing QR code")
    }

    /// The largest whole pixels per module that fits `most` points.
    static func image(_ link: String, scale: CGFloat) -> CGImage? {
        guard let modules = PairingSession.qr(link, scale: 1, correction: "H")?.width, modules > 0 else { return nil }
        let perModule = max(1, (most * scale / CGFloat(modules)).rounded(.down))
        return PairingSession.qr(link, scale: perModule, correction: "H")
    }
}

/// The comparison code as two groups of three in tiles, big enough to check from across a desk.
private struct Digits: View {
    let code: String

    var body: some View {
        let digits = code.filter(\.isNumber).map(String.init)
        HStack(spacing: 16) {
            ForEach([0, 1], id: \.self) { group in
                HStack(spacing: 6) {
                    ForEach(Array(digits.dropFirst(group * 3).prefix(3).enumerated()), id: \.offset) { _, digit in
                        Text(digit)
                            .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                            .frame(width: 46, height: 62)
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.quaternary.opacity(0.7)))
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.separator.opacity(0.6)))
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(digits.joined(separator: " "))
    }
}

/// Pair clicked: the iPhone pulses until it has its token, then turns into a check and the sheet closes itself.
private struct Done: View {
    let name: String
    let paired: Bool
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 22) {
                Image(systemName: paired ? "checkmark.circle.fill" : "iphone.gen3")
                    .font(.system(size: 76))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(paired ? Color.white : Color.accentColor, paired ? Color.green : Color.accentColor.opacity(0.3))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, options: .repeating, isActive: !paired && !reduceMotion)
                    .symbolEffect(.bounce, value: reduceMotion ? false : paired)
                    .frame(height: 92)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(name).font(.title2.weight(.semibold)).lineLimit(2)
                    Text(paired ? "Paired" : "Pairing…").foregroundStyle(.secondary).contentTransition(.opacity)
                }
                .multilineTextAlignment(.center)
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: paired)
            Spacer(minLength: 0)
            Spacer(minLength: 0).frame(maxHeight: 20)
            HStack(spacing: 10) {
                Spacer()
                if paired {
                    Escape(action: close)
                    Button("Done", action: close).keyboardShortcut(.defaultAction).controlSize(.large).buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction).controlSize(.large)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: paired) {
            guard paired else { return }
            try? await Task.sleep(for: .seconds(1.6))
            close()
        }
    }
}

