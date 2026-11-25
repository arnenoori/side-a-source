import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftUI

struct SettingsView: View {
    @Environment(AppRoot.self) private var root
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false
    @AppStorage(PrefKey.terminalFontSize) private var fontSize = 13
    @AppStorage(AppLock.key) private var requireFaceID = true
    @AppStorage(Theme.key, store: SharedStorage.defaults) private var theme = Theme.system
    @AppStorage(DictationPrefs.key, store: SharedStorage.defaults) private var dictatesOnPhone = false

    var body: some View {
        Form {
            Section {
                ForEach(root.macs, id: \.macID) { mac in
                    NavigationLink(value: SettingsPage.mac(mac.macID)) { MacRow(mac: mac.mac, version: mac.link?.state.hello?.app) }
                }
                Button("Pair Another \(root.macs.map(\.mac.kind).shared.titleNoun)", systemImage: "plus") { pairing = true }
                if root.reviewing {
                    Button("Leave Demo", systemImage: "rectangle.portrait.and.arrow.right") { root.leaveDemo() }
                }
            } header: {
                Text(root.macs.map(\.mac.kind).shared.titlePlural)
            }
            if root.macs.count == 1, let mac = root.macs.first {
                Section("Notifications") {
                    PrefToggle("Requests", .requests, mac: mac.macID) { mac.link?.reportPush() }
                    PrefToggle("Questions", .questions, mac: mac.macID) { mac.link?.reportPush() }
                    PrefToggle("Finished", .finished, mac: mac.macID) { mac.link?.reportPush() }
                    PrefToggle("Limit warnings", .limits, mac: mac.macID) { mac.link?.reportPush() }
                    NavigationLink("More", value: SettingsPage.mac(mac.macID))
                }
                .tint(.green)
            }
            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    ForEach(Theme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Accent") { AccentPicker().frame(maxWidth: 260) }
                AppIconStrip()
            }
            Section("Sessions") {
                Picker("Group By", selection: choice(\.groupBy)) {
                    ForEach(GroupBy.allCases) { Text($0.title).tag($0) }
                }
                Picker("Sort By", selection: choice(\.sortBy)) {
                    ForEach(SortBy.allCases) { Text($0.title).tag($0) }
                }
            }
            if root.macs.contains(where: { $0.tools.can(.transcribe) }) {
                Section("Dictation") {
                    Picker("Transcribe On", selection: $dictatesOnPhone) {
                        Text(root.current.mac.name).tag(false)
                        Text("This \(ThisDevice.kind)").tag(true)
                    }
                }
            }
            Section("Security") {
                Toggle("Require \(Biometry.current.name)", isOn: $requireFaceID)
            }
            .tint(.green)
            Section("Terminal") {
                Stepper(value: $fontSize, in: 10...18) {
                    LabeledContent("Font size") { Text("\(fontSize) pt").monospacedDigit() }
                }
                Text(verbatim: "$ swift test --filter SendKey \u{2713}")
                    .font(.system(size: CGFloat(fontSize), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            Section {
                NavigationLink("Privacy", value: SettingsPage.privacy)
                NavigationLink("Acknowledgements", value: SettingsPage.acknowledgements)
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .navigationDestination(for: SettingsPage.self) { page in
            switch page {
            case .privacy: PrivacyView()
            case .acknowledgements: AcknowledgementsView()
            case .mac(let id), .name(let id), .test(let id):
                if let mac = root.model(for: id) {
                    switch page {
                    case .name: MacNameView(mac: mac.mac, macID: id)
                    case .test: if let link = mac.link { TestConnectionView(link: link) } else { TestConnectionView(demo: mac.mac.name) }
                    default: MacDetailView(model: mac)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $pairing) { ScannerScreen(title: "Pair Another \(root.macs.map(\.mac.kind).shared.titleNoun)") }
    }

    private func choice<Value>(_ key: ReferenceWritableKeyPath<SessionsStore, Value>) -> Binding<Value> {
        Binding { root.current.sessions[keyPath: key] } set: { value in for mac in root.macs { mac.sessions[keyPath: key] = value } }
    }

    private var versionLine: String {
        let macs = root.macs.compactMap { mac in mac.link?.state.hello.map { (name: mac.mac.name, hello: $0) } }
        let lines = macs.map { "\(macs.count == 1 ? $0.hello.mac.kind.titleNoun : $0.name) \($0.hello.versionLine)" }
        return ([Hello.version(ClientInfo.current.version, build: ClientInfo.current.build)] + lines).joined(separator: " · ")
    }
}

/// A page pushed inside Settings, as a value so the tab can hold the path: an iPad window changing width builds the
/// tab view again, and a page known only to its link would close.
enum SettingsPage: Hashable {
    case mac(String), name(String), test(String), privacy, acknowledgements
}

enum Support {
    static let address = "support@getsidea.com"
    static let mail = URL(string: "mailto:\(address)")!
}

private struct PrivacyView: View {
    var body: some View {
        Form {
            Text("Side A Remote collects nothing. Sessions go only between your \(ThisDevice.kind) and \(PairedMac.all().map(\.endpoint.kind).shared.your()). The push relay sees device tokens and encrypted payloads.")
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
            Image(systemName: mac.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .overlay(alignment: .bottomTrailing) { ConnectionDot(state: mac.shown).offset(x: 2, y: 2) }
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
                NavigationLink(value: SettingsPage.name(model.macID)) { LabeledContent("Name", value: model.mac.name) }
                LabeledContent("Connection", value: model.mac.state == .live ? model.mac.route?.title ?? "Connected" : model.mac.state.title)
                if let link {
                    LabeledContent("Address", value: (link.state.address ?? link.mac.endpoint.baseURL).host() ?? "")
                    if let hello = link.state.hello {
                        LabeledContent("Side A", value: hello.versionLine)
                    }
                    LabeledContent("This \(ThisDevice.kind)", value: link.mac.deviceName)
                    LabeledContent("Security key") {
                        Text(String(link.mac.endpoint.serverKeyHash.prefix(8)) + "…").monospaced()
                    }
                }
            }
            MacNotificationSections(macID: model.macID, host: model.mac.kind)
            Section {
                NavigationLink("Test Connection", value: SettingsPage.test(model.macID))
            }
            if link != nil {
                Section {
                    Button("Forget This \(model.mac.kind.titleNoun)", role: .destructive) { confirmsForget = true }
                }
            }
        }
        .navigationTitle(model.mac.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { link?.reportPush() }
        .onChange(of: scenePhase) { if $1 != .active { link?.reportPush() } }
        .confirmationDialog("Forget \(model.mac.name)?", isPresented: $confirmsForget, titleVisibility: .visible) {
            Button("Forget This \(model.mac.kind.titleNoun)", role: .destructive) {
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

private struct MacNameView: View {
    let mac: MacConnection
    let macID: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            HStack {
                TextField(mac.reportedName, text: $text)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { dismiss() }
                if !text.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.tertiary)
                        .buttonStyle(.borderless)
                }
            }
        }
        .navigationTitle("Name")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            text = mac.name
            focused = true
        }
        .onDisappear {
            let before = mac.name
            mac.rename(text == mac.reportedName ? nil : text, macID: macID)
            if mac.name != before { WidgetPublisher.shared.refresh() }
        }
    }
}

private struct MacNotificationSections: View {
    let macID: String, host: HostOS
    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationsDenied = false
    @State private var notificationsUndetermined = false

    var body: some View {
        Section {
            if notificationsDenied { OpenNotificationSettings() }
            if notificationsUndetermined {
                Button("Turn On Notifications", systemImage: "bell.badge") {
                    Task {
                        await NotificationsCard.requestAccess()
                        notificationsUndetermined = await NotificationsCard.undetermined()
                    }
                }
            }
            PrefToggle("Requests", .requests, mac: macID)
            PrefToggle("Questions", .questions, mac: macID)
            PrefToggle("Plans", .plans, mac: macID)
            PrefToggle("Finished", .finished, mac: macID)
            PrefToggle("Limit warnings", .limits, mac: macID)
            PrefToggle("Stuck sessions", .health, mac: macID)
            PrefToggle("Autopilot moves", .rotation, mac: macID)
            PrefToggle("\(host.titleNoun) goes quiet", .macQuiet, mac: macID)
            PrefToggle("Time Sensitive for requests", .timeSensitive, mac: macID)
        } header: {
            Text("Notifications")
        }
        .tint(.green)
        .task(id: scenePhase) {
            notificationsDenied = await NotificationsCard.denied()
            notificationsUndetermined = await NotificationsCard.undetermined()
        }
        Section("Live Activity") {
            PrefToggle("On the Lock Screen", .liveActivity, mac: macID) { PushRegistrar.shared.endActivitiesIfOff() }
        }
        .tint(.green)
    }
}

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
