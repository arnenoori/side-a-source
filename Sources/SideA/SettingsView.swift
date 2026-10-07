import Charts
import ServiceManagement
import SideACore
import SwiftUI

enum SettingsTab: String { case accounts, usage, autopilot, general }

/// The one place to manage accounts and preferences; the menu bar and player link here.
struct SettingsView: View {
    @Bindable var store: AccountStore
    @ObservedObject var updates: Updates
    var body: some View {
        TabView(selection: $store.settingsTab) {
            AccountsSettings(store: store)
                .tabItem { Label("Accounts", systemImage: "person.2") }.tag(SettingsTab.accounts)
            UsageSettings(store: store)
                .tabItem { Label("Usage", systemImage: "chart.bar") }.tag(SettingsTab.usage)
            AutopilotSettings(store: store)
                .tabItem { Label("Autopilot", systemImage: "arrow.triangle.2.circlepath") }.tag(SettingsTab.autopilot)
            GeneralSettings(store: store, updates: updates)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
        }
        .frame(width: 520, height: 560)
    }
}

struct AccountsSettings: View {
    @Bindable var store: AccountStore
    @State private var provider: AgentProvider = .claude
    @State private var name = ""
    @State private var email = ""
    @State private var removing: Account?

    var body: some View {
        Form {
            ForEach(AgentProvider.allCases) { provider in
                if let login = store.unknownLogins[provider] {
                    Section {
                        LabeledContent {
                            Button("Add to Side A") { Task { await store.adoptMacLogin(provider) } }
                        } label: {
                            Text("\(provider.title) on this Mac: \(login)")
                        }
                    }
                }
            }
            if store.config.accounts.isEmpty {
                Section { Text("No accounts yet. Add one below.").foregroundStyle(.secondary) }
            }
            ForEach(AgentProvider.allCases) { provider in
                let accounts = store.config.accounts.filter { $0.provider == provider }
                if !accounts.isEmpty {
                    Section(provider.title) {
                        ForEach(accounts) { account in
                            AccountSettingsRow(store: store, account: account, removing: $removing)
                        }
                    }
                }
            }
            Section("Add account") {
                Picker("Agent", selection: $provider) {
                    ForEach(AgentProvider.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                TextField("Name", text: $name, prompt: Text("Personal"))
                TextField("Email", text: $email, prompt: Text("Optional, prefills sign-in"))
                    .autocorrectionDisabled()
                DependencyStatusView(store: store, provider: provider, compact: true)
                HStack {
                    Spacer()
                    Button("Sign in with \(provider.title)") { add() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !store.isInstalled(provider) || store.python == nil)
                }
            }
            if let error = store.error {
                Section { Text(error).foregroundStyle(.red).onTapGesture { store.error = nil } }
            }
        }
        .formStyle(.grouped)
        .alert("Remove \(removing?.name ?? "account")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let removing { store.remove(removing.id) }; removing = nil }
        } message: { Text("Conversations stay.") }
    }

    private func add() {
        guard let id = store.addAccount(name: name, email: email, provider: provider) else { return }
        name = ""; email = ""
        Task { await store.signIn(id) }
    }
}

struct AccountSettingsRow: View {
    @Bindable var store: AccountStore
    let account: Account
    @Binding var removing: Account?
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        let isActive = store.isActive(account)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $draft).labelsHidden().textFieldStyle(.plain).font(.body.weight(.medium))
                    .help("Click to rename")
                    .focused($editing).onSubmit(commit)
                    .onChange(of: editing) { _, focused in if !focused { commit() } }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if account.ready, let usage = store.usage[account.id] {
                MiniBar(label: "5h", window: usage.fiveHour)
                MiniBar(label: "wk", window: usage.weekly)
            }
            Group {
                if store.signingIn.contains(account.id) {
                    ProgressView().controlSize(.small)
                } else if !account.ready {
                    Button("Sign in") { Task { await store.signIn(account.id) } }
                } else if isActive {
                    // Which login new commands use; every signed-in account is healthy.
                    Text("In use").font(.caption.weight(.medium)).foregroundStyle(.green)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.green.opacity(0.12), in: .capsule)
                        .help(account.provider == .claude ? "New claude commands use this account" : "Codex on this Mac is signed in to this account")
                } else if account.provider == .claude {
                    Button("Use") { Task { await store.activate(account.id) } }
                }
            }.frame(width: 64, alignment: .trailing)
            Menu {
                Button("Rename") { editing = true }
                Toggle("Include in Autopilot", isOn: Binding(get: { account.allowAuto }, set: { store.setAuto(account.id, $0) }))
                Divider()
                Button("Sign in again") { Task { await store.signIn(account.id) } }.disabled(isActive)
                Button("Sign out") { store.signOut(account.id) }.disabled(isActive || !account.ready)
                Divider()
                Button("Remove…", role: .destructive) { removing = account }.disabled(isActive)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Options for \(account.name)")
        }
        .onAppear { draft = account.name }
        .onChange(of: account.name) { _, name in if !editing { draft = name } }
    }

    private var subtitle: String {
        guard account.ready else { return "Not signed in" }
        let identity = account.email.isEmpty ? "Connected" : account.email
        return account.allowAuto ? identity : "\(identity) · Autopilot skips it"
    }
    private func commit() {
        if !store.rename(account.id, draft) { draft = account.name }
    }
}

struct UsageSettings: View {
    @Bindable var store: AccountStore
    var body: some View {
        Form {
            let weekly = store.config.accounts.filter { $0.ready && store.usage[$0.id]?.weekly != nil }
            if !weekly.isEmpty {
                Section("This week") {
                    ForEach(weekly) { PaceRow(account: $0, window: store.usage[$0.id]!.weekly!) }
                }
            }
            if let report = store.report {
                Section {
                    HStack(spacing: 10) {
                        let days = Dictionary(report.days.map { ($0.date ?? "", $0.total) }, uniquingKeysWith: +)
                        let sum = { (range: ClosedRange<Int>) in range.reduce(0) { $0 + (days[MenuPlayer.day(-$1)] ?? 0) } }
                        StatTile(title: "Today", value: sum(0...0), baseline: Double(sum(1...29)) / 29, comparison: "daily average")
                        StatTile(title: "7 days", value: sum(0...6), baseline: Double(sum(7...13)), comparison: "the week before")
                        StatTile(title: "30 days", value: sum(0...29))
                    }
                }
                Section("Tokens per day") {
                    Chart(report.dayModels ?? report.days, id: \.self) { row in
                        BarMark(x: .value("Day", Self.day(row.date), unit: .day), y: .value("Tokens", row.total))
                            .foregroundStyle(by: .value("Model", ModelName.short(row.model)))
                    }
                    .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { Text(TokenCount.short(value.as(Int.self) ?? 0)) } } }
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 170)
                }
                Section("When you work") { HourStrip(activity: report.activity) }
                Section("Projects") { shares(report.projects.prefix(6).map { (URL(fileURLWithPath: $0.project ?? "").lastPathComponent, $0.total) }) }
                Section("Models") { shares(report.models.prefix(5).map { (ModelName.short($0.model), $0.total) }) }
            } else {
                Section {
                    HStack { ProgressView().controlSize(.small); Text("Reading transcripts…") }
                }
            }
        }
        .formStyle(.grouped)
        .task { await store.refreshReport() }
    }
    static func day(_ text: String?) -> Date {
        (try? Date(text ?? "", strategy: .iso8601.year().month().day())) ?? .distantPast
    }
    private func shares(_ items: [(String, Int)]) -> some View {
        let all = Double(max(items.map(\.1).reduce(0, +), 1))
        return ForEach(items, id: \.0) { name, total in
            LabeledContent {
                Text("\(TokenCount.short(total))  \(Int((Double(total) / all * 100).rounded()))%").monospacedDigit()
            } label: {
                Text(name).lineLimit(1).truncationMode(.middle)
                ProgressView(value: Double(total), total: all).progressViewStyle(.linear)
            }
        }
    }
}

/// Weekly use against how much of the week has passed, with what that pace means.
struct PaceRow: View {
    let account: Account
    let window: UsageWindow
    var body: some View {
        let used = min(max(window.percent, 0), 100)
        let elapsed = elapsedShare
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(account.name).font(.body.weight(.medium))
                Text(account.provider.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(verdict(used: used, elapsed: elapsed)).font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(used >= Planner.full ? Color.red : .accentColor).frame(width: proxy.size.width * used / 100)
                    // Where usage would be if spread evenly over the week.
                    Rectangle().fill(.primary.opacity(0.55)).frame(width: 1.5, height: 10).offset(x: proxy.size.width * elapsed - 0.75)
                }
            }.frame(height: 6)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
    private var elapsedShare: Double {
        guard let reset = window.resetsAt else { return 0 }
        let week = 7 * 86_400.0
        return min(max((Date().timeIntervalSince1970 - (reset - week)) / week, 0), 1)
    }
    private func verdict(used: Double, elapsed: Double) -> String {
        let resets = window.resetsAt.map { "resets \(UsageBar.format($0))" } ?? ""
        if used >= Planner.full { return "Limited, \(resets)" }
        guard elapsed > 0.05 else { return "\(Int(used))% used, \(resets)" }
        let projected = used / elapsed
        if projected >= 100 { return "Runs out before it \(resets)" }
        let unused = Int(100 - projected)
        return unused > 10 ? "About \(unused)% will go unused" : "On pace, \(resets)"
    }
}

struct StatTile: View {
    let title: String
    let value: Int
    var baseline: Double? = nil
    var comparison = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(TokenCount.short(value)).font(.title2.weight(.semibold)).monospacedDigit()
            if let baseline, baseline > 0 {
                let change = (Double(value) - baseline) / baseline * 100
                Text("\(change >= 0 ? "+" : "")\(Int(change.rounded()))% vs \(comparison)")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("tokens").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Responses per hour of the day over the report period, as a heat strip.
struct HourStrip: View {
    let activity: [ActivitySpan]
    var body: some View {
        let hours = (0..<24).map { hour in activity.reduce(0) { $0 + ($1.hours.indices.contains(hour) ? $1.hours[hour] : 0) } }
        let peak = Double(max(hours.max() ?? 0, 1))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.08 + 0.92 * Double(hours[hour]) / peak))
                        .frame(height: 22).help("\(TokenCount.clock(hour * 60)): \(hours[hour]) responses")
                }
            }
            HStack {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(TokenCount.clock(hour * 60)).font(.caption2).foregroundStyle(.secondary)
                    if hour != 18 { Spacer() }
                }
                Spacer()
            }
            if let busiest = hours.indices.max(by: { hours[$0] < hours[$1] }), hours[busiest] > 0 {
                Text("Busiest around \(TokenCount.clock(busiest * 60))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

enum ModelName {
    /// "claude-opus-5-5-20260101" reads as "Opus 5.5".
    static func short(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "Other" }
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init).filter { $0.count < 8 }
        guard let name = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return name.capitalized + (version.isEmpty ? "" : " " + version)
    }
}

struct AutopilotSettings: View {
    @Bindable var store: AccountStore
    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { store.config.smartMode }, set: { _ in store.toggleSmart() })) {
                    Text("Autopilot")
                }
                Toggle(isOn: Binding(get: { store.shellSwitching }, set: { value in Task { await store.setShellSwitching(value) } })) {
                    Text("Switch in Terminal")
                    Text("Adds one line to ~/.zshrc.")
                }
                Toggle(isOn: Binding(get: { store.limitHook }, set: { value in Task { await store.setLimitHook(value) } })) {
                    Text("Switch instantly on a limit")
                    Text("Adds a silent Claude Code hook.")
                }
            }
            Section("Schedule") {
                if let schedule = store.schedule {
                    LabeledContent("Your hours", value: "\(TokenCount.clock(schedule.start))–\(TokenCount.clock(schedule.end))")
                    LabeledContent("Warm-up from", value: TokenCount.clock(schedule.start - WorkSchedule.lead))
                } else {
                    Text("Learning your hours").foregroundStyle(.secondary)
                }
            }
            Section("How it decides") {
                LabeledContent("Picks", value: "Quota closest to expiring, by plan size")
                LabeledContent("Switches at", value: "\(Int(Planner.full))%")
                LabeledContent("Warm-up", value: "One tiny Haiku message")
            }
            Section {
                LabeledContent("Claude", value: "New terminal commands")
                LabeledContent("Codex", value: "Tracked; switch with codex login")
            }
        }.formStyle(.grouped)
    }
}

struct GeneralSettings: View {
    @Bindable var store: AccountStore
    @ObservedObject var updates: Updates
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("tourSeen") private var tourSeen = false
    @AppStorage("playerEnabled") private var playerEnabled = false
    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: { store.setLaunchAtLogin($0); launchAtLogin = SMAppService.mainApp.status == .enabled }))
                Toggle("Show only in the menu bar", isOn: Binding(get: { store.config.menuBarOnly }, set: { store.setMenuBarOnly($0) }))
                LabeledContent("Guided tour") { Button("Show again") { tourSeen = false } }
                Toggle(isOn: $playerEnabled) {
                    Text("3D player")
                    Text("A pocket disc player for your accounts, from the menu.")
                }
            }
            Section("Tools") {
                DependencyStatusView(store: store, provider: .claude)
                DependencyStatusView(store: store, provider: .codex, compact: true)
            }
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $updates.automaticallyChecks)
                Toggle("Install updates automatically", isOn: $updates.automaticallyInstalls)
                    .disabled(!updates.automaticallyChecks)
                LabeledContent { UpdateButton(updates: updates) } label: { Text("Signed, notarized updates") }
            }
            Section("Privacy") {
                UsagePreference(analytics: store.analytics)
                LabeledContent {
                    Button("Save diagnostics…") { store.saveDiagnostics() }
                } label: { Link("Privacy details", destination: URL(string: "https://getsidea.com/index.md")!) }
            }
        }.formStyle(.grouped)
    }
}
