import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftUI

/// The Settings tab. Toggles are green so amber keeps
/// meaning "needs you".
struct SettingsView: View {
    @Environment(AppRoot.self) private var root
    @State private var pairing = false
    @AppStorage("terminal.fontSize") private var fontSize = 13
    @AppStorage(AppLock.key) private var requireFaceID = true

    var body: some View {
        // Switches are green as in Settings, so only their sections take the tint.
        Form {
            Section {
                ForEach(root.macs, id: \.macID) { mac in
                    NavigationLink { MacDetailView(model: mac) } label: { MacRow(mac: mac.mac, version: mac.link?.state.hello?.app) }
                }
                Button("Pair Another Mac", systemImage: "plus") { pairing = true }
                if root.reviewing {
                    Button("Leave Demo", systemImage: "rectangle.portrait.and.arrow.right") { root.leaveDemo() }
                }
            } header: {
                Text("Macs")
            }
            Section("Appearance") {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Accent")
                    AccentPicker()
                }
            }
            Section("Security") {
                Toggle("Require Face ID", isOn: $requireFaceID)
            }
            .tint(.green)
            Section("Terminal") {
                Stepper(value: $fontSize, in: 10...18) {
                    LabeledContent("Font size") { Text("\(fontSize) pt").monospacedDigit() }
                }
            }
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
        // Straight to the scanner, no welcome or Tailscale step.
        .fullScreenCover(isPresented: $pairing) { ScannerScreen(title: "Pair Another Mac") }
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
                Text([version.map { "Side A \($0)" }, mac.state == .live ? mac.status : Formatting.age(of: mac.lastSeen)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One paired Mac: where it is, what it may notify about, Test Connection, and Forget. The demo's Macs have no link,
/// and still show how they're reached and what each may notify about.
struct MacDetailView: View {
    let model: AppModel
    @Environment(AppRoot.self) private var root
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmsForget = false

    private var link: LiveLink? { model.link }

    var body: some View {
        Form {
            Section {
                LabeledContent("Connection", value: model.mac.state == .live ? model.mac.route?.title ?? "Connected" : model.mac.state.title)
                if let link {
                    LabeledContent("Address", value: (link.state.address ?? link.mac.endpoint.baseURL).host() ?? "")
                    if let hello = link.state.hello {
                        LabeledContent("Side A", value: hello.versionLine)
                    }
                    LabeledContent("This iPhone", value: link.mac.deviceName)
                    LabeledContent("Security key") {
                        Text(String(link.mac.endpoint.serverKeyHash.prefix(8)) + "…").monospaced()
                    }
                }
            }
            MacNotificationSections(macID: model.macID)
            Section {
                if let link {
                    NavigationLink("Test Connection") { TestConnectionView(link: link) }
                } else {
                    NavigationLink("Test Connection") { TestConnectionView(demo: model.mac.name) }
                }
            }
            if link != nil {
                Section {
                    Button("Forget This Mac", role: .destructive) { confirmsForget = true }
                }
            }
        }
        .navigationTitle(model.mac.name)
        .navigationBarTitleDisplayMode(.inline)
        // The Mac sends only what's on here, so it hears the switches once the user is done with them: on leaving the page,
        // or the app, since Settings is a tab that can stay open.
        .onDisappear { link?.reportPush() }
        .onChange(of: scenePhase) { if $1 != .active { link?.reportPush() } }
        .confirmationDialog("Forget \(model.mac.name)?", isPresented: $confirmsForget, titleVisibility: .visible) {
            Button("Forget This Mac", role: .destructive) {
                // Back to the list first, so the row is seen leaving. No haptic: the dialog was the confirmation.
                let macID = model.macID, animation = Motion.smooth(reduceMotion)
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

/// A Mac's Notifications and Live Activity switches.
private struct MacNotificationSections: View {
    let macID: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationsDenied = false

    var body: some View {
        Section {
            if notificationsDenied { OpenNotificationSettings() }
            PrefToggle("Requests", .requests, mac: macID)
            PrefToggle("Questions", .questions, mac: macID)
            PrefToggle("Plans", .plans, mac: macID)
            PrefToggle("Finished", .finished, mac: macID)
            PrefToggle("Limit warnings", .limits, mac: macID)
            PrefToggle("Stuck sessions", .health, mac: macID)
            PrefToggle("Autopilot moves", .rotation, mac: macID)
            PrefToggle("Time Sensitive for requests", .timeSensitive, mac: macID)
        } header: {
            Text("Notifications")
        }
        .tint(.green)
        .task(id: scenePhase) { notificationsDenied = await NotificationsCard.denied() }
        Section("Live Activity") {
            PrefToggle("On the Lock Screen", .liveActivity, mac: macID) { PushRegistrar.shared.endActivitiesIfOff() }
        }
        .tint(.green)
    }
}

/// One of a Mac's notification switches, stored under its own key.
private struct PrefToggle: View {
    let title: String
    let changed: (() -> Void)?
    @AppStorage private var isOn: Bool

    init(_ title: String, _ key: NotificationPrefs.Key, mac: String, changed: (() -> Void)? = nil) {
        self.title = title
        self.changed = changed
        _isOn = AppStorage(wrappedValue: key.value(mac: mac), key.key(mac: mac))
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
            .onChange(of: isOn) { changed?() }
    }
}
