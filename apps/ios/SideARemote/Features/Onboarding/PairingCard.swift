import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftUI

/// The glass card that walks through pairing (setup, "Pairing"): "Connecting to MacBook Pro…", the
/// comparison code to check on the Mac, then "Connected to MacBook Pro" before Sessions takes over.
/// A failure is one sentence and one button.
struct PairingCard: View {
    let run: PairingRun
    /// Back to where the invitation came from: the scanner, or out.
    let back: () -> Void

    @Environment(AppRoot.self) private var root
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var connected = false
    @State private var pairedMac: PairedMac?
    @AppStorage(Accent.key, store: Accent.store) private var accent = Accent.blue

    var body: some View {
        Group {
            switch run.phase {
            case .failed(let failure): FailureCard(failure: failure, act: act)
            case .comparing(let code, let deadline): comparing(code, deadline: deadline)
            case .paired: paired
            case .running: connecting
            }
        }
        .padding(Space.l)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: .rect(cornerRadius: 32, style: .continuous))
        .padding(Space.m)
        .animation(Motion.smooth(reduceMotion), value: run.phase)
        .sensoryFeedback(trigger: run.phase) { _, phase in
            switch phase {
            case .paired: .success
            case .failed: .error
            case .comparing: .impact(weight: .light)
            default: nil
            }
        }
        .task(id: run.phase) {
            guard case .paired(let mac) = run.phase else { return }
            withAnimation(Motion.smooth(reduceMotion)) { connected = true }
            // The first pairing stops here for an accent; pairing again goes straight on.
            guard Accent.chosen else { pairedMac = mac; return }
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(Motion.smooth(reduceMotion)) { root.paired(mac) }
            // Another Mac, or Pair Again, leaves the rest of the app as it was: the scanner closes over it.
            dismiss()
        }
    }

    private var connecting: some View {
        HStack(spacing: Space.s) {
            ProgressView()
            Text("Connecting to \(run.macName)…").font(.headline)
            Spacer(minLength: 0)
            Button("Cancel") { run.cancel(); back() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func comparing(_ code: String, deadline: Date) -> some View {
        VStack(spacing: Space.m) {
            Text("Does your Mac show this code?")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(code)
                .font(.system(size: 44, weight: .semibold, design: .monospaced))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.numericText())
                .accessibilityLabel(code.map { String($0) }.joined(separator: " "))
            Text("Then click Pair on your Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Doesn't Match", role: .destructive) { run.cancel(); back() }
                Spacer()
                Countdown(until: deadline)
            }
            .padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity)
    }

    private var paired: some View {
        VStack(spacing: Space.s) {
            // The check draws itself in; its room is kept so nothing below moves when it does.
            ZStack {
                if connected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 52))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.done)
                        .transition(.symbolEffect(.drawOn))
                }
            }
            .frame(height: 62)
            .accessibilityHidden(true)
            Text("Connected to \(run.macName)")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if let pairedMac {
                Text("Choose an accent")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, Space.xs)
                AccentPicker()
                Button {
                    // Stored even when Blue was left as it was, so pairing again doesn't ask.
                    Accent.store.set(accent.rawValue, forKey: Accent.key)
                    withAnimation(Motion.smooth(reduceMotion)) { root.paired(pairedMac) }
                    dismiss()
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.top, Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .transition(.blurReplace)
    }

    private func act(_ action: PairingFailure.Action) {
        switch action {
        case .tryAgain: run.start()
        case .scanAgain, .scanNewCode: back()
        case .openTailscale: openURL(Tailscale.app)
        case .openSettings: openURL(URL(string: UIApplication.openSettingsURLString)!)
        case .appStore: openURL(URL(string: "itms-apps://apps.apple.com/app/side-a-remote")!)
        }
    }
}

/// "0:52", counting down to the Mac's deadline.
private struct Countdown: View {
    let until: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
            Text(String(format: "%d:%02d", left / 60, left % 60))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(countsDown: true))
        }
    }
}

/// One failure, one primary action, never an alert (setup, "Failure cards").
struct FailureCard: View {
    let failure: PairingFailure
    let act: (PairingFailure.Action) -> Void

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(Color.amber)
                .accessibilityHidden(true)
            Text(failure.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = failure.detail {
                DisclosureGroup("Details") {
                    Text(detail)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Space.xxs)
                }
                .font(.subheadline)
                .tint(.secondary)
            }
            VStack(spacing: Space.s) {
                PrimaryAction(action: failure.primary, waits: failure.retryAfter, act: act)
                if let secondary = failure.secondary {
                    Button(secondary.title) { act(secondary) }
                        .font(.subheadline)
                }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }

    /// 429's Try Again stays disabled with a countdown.
    private struct PrimaryAction: View {
        let action: PairingFailure.Action
        let waits: Double?
        let act: (PairingFailure.Action) -> Void
        @State private var until: Date?

        var body: some View {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = until.map { max(0, Int($0.timeIntervalSince(context.date).rounded(.up))) } ?? 0
                Button { act(action) } label: {
                    Text(left > 0 ? "\(action.title) in \(left) s" : action.title)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.glassProminent)
                .disabled(left > 0)
            }
            .onAppear { until = waits.map { Date.now.addingTimeInterval($0) } }
        }
    }
}

extension PairingFailure.Action {
    var title: String {
        switch self {
        case .tryAgain: "Try Again"
        case .scanAgain: "Scan Again"
        case .scanNewCode: "Scan New Code"
        case .openTailscale: "Open Tailscale"
        case .openSettings: "Open Settings"
        case .appStore: "App Store"
        }
    }
}

/// Pairing opened from a link: the card on its own, over a quiet background. A link can come from anywhere,
/// an agent's output included, so nothing starts until the user says which Mac and confirms.
struct PairingScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var run: PairingRun
    @State private var confirmed = false
    /// Only the same Mac paired before is replaced; another Mac is added beside the ones there.
    private let current: PairedMac?
    private let otherTailnet: PairedMac?
    private let identityWarning: String?

    init(invitation: PairingClient.Invitation) {
        run = PairingRun(invitation: invitation)
        current = PairedMac.matching(invitation)
        otherTailnet = PairedMac.otherTailnet(invitation)
        identityWarning = PairedMac.identityWarning(invitation)
    }

    var body: some View {
        Group {
            if confirmed {
                PairingCard(run: run) { dismiss() }
            } else {
                ConfirmPairing(invitation: run.invitation, name: run.macName, replacing: current?.endpoint.name, identityWarning: identityWarning,
                               otherTailnet: otherTailnet.map { "\(run.macName) is on a different tailnet from \($0.endpoint.name). \(OtherTailnet.message)" }) {
                    withAnimation(Motion.smooth(reduceMotion)) { confirmed = true }
                    run.start(replacing: current)
                } cancel: {
                    dismiss()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

/// "Pair with MacBook Pro?", the address it will reach, and which Mac it replaces.
private struct ConfirmPairing: View {
    let invitation: PairingClient.Invitation
    let name: String
    let replacing: String?
    let identityWarning: String?
    let otherTailnet: String?
    let pair: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: Space.xxs) {
                Text("Pair with \(RequestText.visible(name))?")
                    .font(.headline)
                Text(invitation.address)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                if let replacing {
                    Text("This replaces \(replacing).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, Space.xxs)
                }
                if let identityWarning {
                    Label(identityWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                        .padding(.top, Space.xxs)
                }
                if let otherTailnet {
                    Text(otherTailnet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, Space.xxs)
                }
            }
            .multilineTextAlignment(.center)
            VStack(spacing: Space.xs) {
                Button(action: pair) {
                    Text(otherTailnet == nil && identityWarning == nil ? "Pair" : "Pair Anyway").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.glassProminent)
                .tint(identityWarning == nil ? nil : .red)
                Button(action: cancel) {
                    Text("Cancel").frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
        .padding(Space.l)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: .rect(cornerRadius: 32, style: .continuous))
        .padding(Space.m)
    }
}

#if DEBUG
/// `--pairing-sample comparing|paired|failed`: the card at one phase, for screenshots.
struct PairingSampleScreen: View {
    let run: PairingRun

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--pairing-sample"), index + 1 < arguments.count else { return nil }
        switch arguments[index + 1] {
        case "comparing": run = .sample(.comparing(code: "035 223", deadline: .now.addingTimeInterval(52)))
        case "paired":
            // The accent step shows only until one is picked; the sample always shows it.
            Accent.store.removeObject(forKey: Accent.key)
            run = .sample(.paired(PairedMac(endpoint: Endpoint(macID: "m", baseURL: URL(string: "https://100.101.12.4:47800")!,
                                                                          serverKeyHash: "", name: "MacBook Pro"),
                                                       deviceID: "d", deviceName: "iPhone")))
        case "failed": run = .sample(.failed(PairingFailure(title: "Couldn't connect securely to MacBook Pro.",
                                                            detail: "TLS error -1200 (-9802)", primary: .tryAgain)))
        default: run = .sample(.running(.reaching))
        }
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            PairingCard(run: run) {}
        }
    }
}

#Preview("Comparing") {
    PairingSampleScreen(arguments: ["--pairing-sample", "comparing"]).environment(AppRoot())
}

#Preview("Failed") {
    PairingSampleScreen(arguments: ["--pairing-sample", "failed"]).environment(AppRoot())
}
#endif
