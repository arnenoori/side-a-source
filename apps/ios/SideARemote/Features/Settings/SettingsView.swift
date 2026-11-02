import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftUI

/// Settings, pushed from the Sessions menu (section 4.13). Toggles are green so amber keeps
/// meaning "needs you".
struct SettingsView: View {
    @Environment(AppRoot.self) private var root
    @State private var pairing = false
    @AppStorage("notify.requests") private var requests = true
    @AppStorage("notify.questions") private var questions = true
    @AppStorage("notify.plans") private var plans = true
    @AppStorage("notify.finished") private var finished = true
    @AppStorage("notify.limits") private var limits = false
    /// NotificationPrefs.health: a session that's stuck, looping or failing.
    @AppStorage("notify.health") private var health = true
    @AppStorage("notify.rotation") private var rotation = false
    @AppStorage("notify.timeSensitive") private var timeSensitive = true
    @AppStorage("notify.quietWhileWatching") private var quietWhileWatching = true
    @AppStorage("activity.enabled") private var liveActivity = true
    @AppStorage("activity.limit") private var activityLimit = true
    @AppStorage("terminal.fontSize") private var fontSize = 13
    @AppStorage("terminal.predictiveEcho") private var predictiveEcho = true
    @AppStorage(AppLock.key) private var requireFaceID = true
    @State private var notificationsDenied = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // Switches are green as in Settings, so only their sections take the tint.
        Form {
            Section("Macs") {
                ForEach(root.macs, id: \.macID) { mac in
                    if let link = mac.link {
                        NavigationLink { MacDetailView(link: link) } label: { MacRow(mac: mac.mac, version: link.state.hello?.app) }
                    } else {
                        MacRow(mac: mac.mac, version: nil)
                    }
                }
                Button("Pair Another Mac", systemImage: "plus") { pairing = true }
                if root.reviewing {
                    Button("Leave Demo", systemImage: "rectangle.portrait.and.arrow.right") { root.leaveDemo() }
                }
            }
            Section("Appearance") {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Accent")
                    AccentPicker()
                }
            }
            Section {
                if notificationsDenied { OpenNotificationSettings() }
                Toggle("Requests", isOn: $requests)
                Toggle("Questions", isOn: $questions)
                Toggle("Plans", isOn: $plans)
                Toggle("Finished", isOn: $finished)
                Toggle("Limit warnings", isOn: $limits)
                Toggle("Stuck sessions", isOn: $health)
                Toggle("Autopilot moves", isOn: $rotation)
                Toggle("Time Sensitive for requests", isOn: $timeSensitive)
                Toggle("Quiet while I'm watching the session", isOn: $quietWhileWatching)
            } header: {
                Text("Notifications")
            }
            .tint(.green)
            Section("Live Activity") {
                Toggle("On the Lock Screen", isOn: $liveActivity)
                Toggle("Show the tightest limit", isOn: $activityLimit)
            }
            .tint(.green)
            Section("Security") {
                Toggle("Require Face ID", isOn: $requireFaceID)
            }
            .tint(.green)
            Section("Terminal") {
                Stepper(value: $fontSize, in: 10...18) {
                    LabeledContent("Font size") { Text("\(fontSize) pt").monospacedDigit() }
                }
                Toggle("Predictive echo", isOn: $predictiveEcho)
            }
            .tint(.green)
            Section {
                NavigationLink("Privacy") { PrivacyView() }
                NavigationLink("Acknowledgements") { AcknowledgementsView() }
                Link("Contact Support", destination: Support.mail)
            } header: {
                Text("About")
            } footer: {
                Text(versionLine)
                    .font(.caption2)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Settings")
        .task(id: scenePhase) { notificationsDenied = await NotificationsCard.denied() }
        // setup.md §D: straight to the scanner, no welcome or Tailscale step.
        .fullScreenCover(isPresented: $pairing) { ScannerScreen(title: "Pair Another Mac") }
        // Each Mac sends only what's on here, so each hears the switches once the user is done with them.
        .onDisappear { for mac in root.macs { mac.link?.reportPush() } }
        .onChange(of: liveActivity) { PushRegistrar.shared.endActivitiesIfOff() }
    }

    /// "1.0 (11) · Mac 1.0 (12) · protocol 1": this app, then each paired Mac its hello has described, by name when
    /// there are several.
    private var versionLine: String {
        let macs = root.macs.compactMap { mac in mac.link?.state.hello.map { (name: mac.mac.name, hello: $0) } }
        let lines = macs.map { "\(macs.count == 1 ? "Mac" : $0.name) \($0.hello.versionLine)" }
        return ([Hello.version(ClientInfo.current.version, build: ClientInfo.current.build)] + lines).joined(separator: " · ")
    }
}

/// Support and privacy questions both go here; the App Store listing gives the same address.
enum Support {
    static let address = "support@getsidea.com"
    static let mail = URL(string: "mailto:\(address)")!
}

private struct PrivacyView: View {
    var body: some View {
        Form {
            Text("Side A Remote collects nothing. Sessions go only between your iPhone and your Mac. The push relay sees device tokens and encrypted payloads.")
            Section("Questions") {
                Link(Support.address, destination: Support.mail)
            }
        }
        .navigationTitle("Privacy")
    }
}

private struct AcknowledgementsView: View {
    private let items = [("SwiftTerm", "MIT License"), ("Codeman", "MIT License"), ("Paseo", "Apache License 2.0 · changed files marked"), ("Happy", "MIT License")]

    var body: some View {
        List(items, id: \.0) { item in
            VStack(alignment: .leading, spacing: 2) {
                Text(item.0)
                Text(item.1).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Acknowledgements")
    }
}

private struct MacRow: View {
    let mac: MacConnection
    let version: String?

    var body: some View {
        HStack(spacing: Space.s) {
            Circle().fill(mac.state == .live ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.name)
                Text([version.map { "Side A \($0)" }, mac.state == .live ? "Connected" : Formatting.age(of: mac.lastSeen)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One paired Mac: where it is, Test Connection, and Forget.
struct MacDetailView: View {
    let link: LiveLink
    @Environment(AppRoot.self) private var root
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmsForget = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Address", value: (link.state.address ?? link.mac.endpoint.baseURL).host() ?? "")
                if let hello = link.state.hello {
                    LabeledContent("Side A", value: hello.versionLine)
                }
                LabeledContent("This iPhone", value: link.mac.deviceName)
                LabeledContent("Security key") {
                    Text(String(link.mac.endpoint.serverKeyHash.prefix(8)) + "…").monospaced()
                }
            }
            Section {
                NavigationLink("Test Connection") { TestConnectionView(mac: link.mac) }
            }
            Section {
                Button("Forget This Mac", role: .destructive) { confirmsForget = true }
            }
        }
        .navigationTitle(link.mac.endpoint.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Forget \(link.mac.endpoint.name)?", isPresented: $confirmsForget, titleVisibility: .visible) {
            Button("Forget This Mac", role: .destructive) {
                // Back to the list first, so the row is seen leaving. No haptic: the dialog was the confirmation.
                let macID = link.mac.endpoint.macID, animation = Motion.smooth(reduceMotion)
                dismiss()
                Task { [root] in
                    try? await Task.sleep(for: .milliseconds(400))
                    withAnimation(animation) { root.forget(macID) }
                }
            }
        } message: {
            Text("You'll need to pair again to use it.")
        }
    }
}
