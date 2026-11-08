import Charts
import ServiceManagement
import SideACore
import SideAProtocol
import SwiftUI

/// In tab order; ⌘1–⌘7 follow it.
enum SettingsTab: String, CaseIterable { case accounts, autopilot, usage, notifications, remote, setup, general }

/// The one place to manage accounts and preferences; the menu bar and player link here.
struct SettingsView: View {
    @Bindable var store: AccountStore
    @ObservedObject var updates: Updates
    @State private var query = ""
    @FocusState private var searching: Bool
    var body: some View {
        VStack(spacing: 0) {
            TextField("Search settings", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
                .onExitCommand { query = "" }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                tabs
            } else {
                SettingsResults(query: query) { tab in
                    store.settingsTab = tab
                    query = ""
                    searching = false
                }
            }
        }
        .frame(width: 520, height: 600)
        .background { TabShortcuts(store: store) { searching = true } }
    }

    private var tabs: some View {
        TabView(selection: $store.settingsTab) {
            AccountsSettings(store: store).settingsTab(.accounts)
            AutopilotSettings(store: store).settingsTab(.autopilot)
            UsageSettings(store: store).settingsTab(.usage)
            NotificationSettings(store: store).settingsTab(.notifications)
            RemoteSettings(store: store).settingsTab(.remote)
            SetupSettings(store: store).settingsTab(.setup)
            GeneralSettings(store: store, updates: updates).settingsTab(.general)
        }
    }
}

private extension View {
    func settingsTab(_ tab: SettingsTab) -> some View {
        tabItem { Label(tab.title, systemImage: tab.symbol) }.tag(tab)
    }
}

/// ⌘1–⌘7 pick a tab, ⌘F searches and ⌘⇧S opens Sessions. Invisible buttons, because a menu-bar-only Side A has no menu bar to hold them.
private struct TabShortcuts: View {
    let store: AccountStore
    let search: () -> Void
    var body: some View {
        ZStack {
            ForEach(Array(SettingsTab.allCases.enumerated()), id: \.offset) { index, tab in
                Button("") { store.settingsTab = tab }.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Button("", action: search).keyboardShortcut("f", modifiers: .command)
            Button("") { store.openSessions() }.keyboardShortcut("s", modifiers: [.command, .shift])
        }
        .opacity(0).accessibilityHidden(true)
    }
}

struct AccountsSettings: View {
    @Bindable var store: AccountStore
    @State private var removing: Account?
    @State private var adding = false

    var body: some View {
        Form {
            ForEach(AgentProvider.allCases) { provider in
                if let login = store.loginsToAdd[provider] {
                    Section {
                        LabeledContent {
                            Button("Add to Side A") { Task { await store.adoptMacLogin(provider) } }
                        } label: {
                            Text("\(provider.title) on this Mac: \(login)")
                        }
                    }
                }
            }
            if let elsewhere = store.report?.elsewhere, !elsewhere.isEmpty {
                Section("On your other Macs") {
                    ForEach(elsewhere, id: \.self) { remote in
                        LabeledContent {
                            Button("Sign In Here") {
                                if let id = store.addAccount(name: remote.name, email: remote.email, provider: remote.provider) { Task { await store.signIn(id) } }
                            }.disabled(!store.isInstalled(remote.provider) || store.python == nil)
                        } label: {
                            Text(remote.name)
                            Text("\(remote.provider.title) · \(remote.email) · on \(remote.machine)")
                        }
                    }
                }
            }
            if store.config.accounts.isEmpty {
                Section { Text("No accounts yet.").foregroundStyle(.secondary) }
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
            Section {
                HStack {
                    Spacer()
                    Button("Add Account…") { adding = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let error = store.error {
                Section { Text(error).foregroundStyle(.red).onTapGesture { store.error = nil } }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: focusAdd)
        .onChange(of: store.addingAccount) { focusAdd() }
        .sheet(isPresented: $adding) { AddAccountSheet(store: store) }
        .alert("Remove \(removing?.name ?? "account")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let removing { store.remove(removing.id) }; removing = nil }
        } message: { Text("Conversations stay.") }
    }

    private func focusAdd() {
        guard store.addingAccount else { return }
        store.addingAccount = false
        adding = true
    }
}

struct AddAccountSheet: View {
    @Bindable var store: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var provider: AgentProvider = .claude
    @State private var name = ""
    @State private var email = ""
    @FocusState private var naming: Bool

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Agent", selection: $provider) {
                        ForEach(AgentProvider.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    TextField("Name", text: $name, prompt: Text("Optional"))
                        .focused($naming)
                    TextField("Email", text: $email, prompt: Text("Optional, prefills sign-in"))
                        .autocorrectionDisabled()
                    DependencyStatusView(store: store, provider: provider, compact: true)
                } header: {
                    Text("Add an account")
                } footer: {
                    Text("Opens \(provider.title)'s sign-in in your browser.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            // Accounts shows errors behind this sheet, where they can't be seen while it's open.
            if let error = store.error {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Account") { add() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.isInstalled(provider) || store.python == nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
        .onAppear { naming = true }
    }

    private func add() {
        guard let id = store.addAccount(name: name, email: email, provider: provider) else { return }
        dismiss()
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
                MiniBar(label: "5h", window: usage.fiveHour, showsReset: true)
                MiniBar(label: "wk", window: usage.weekly, showsReset: true)
                ForEach(usage.modelLimits, id: \.id) { MiniBar(label: LimitText.name($0), window: $0, showsReset: true) }
            }
            Group {
                switch store.waking.contains(account.id) ? .busy : store.rowAction(for: account) {
                case .busy:
                    ProgressView().controlSize(.small)
                case .signIn:
                    Button("Sign In") { Task { await store.signIn(account.id) } }
                case .renew:
                    Button("Renew") { Task { await store.wake(account.id) } }
                        .help("Has Claude Code renew this login; no model runs and no quota is used")
                case .inUse:
                    // Which login new commands use; every signed-in account is healthy.
                    Text("In use").font(.caption.weight(.medium)).foregroundStyle(.green)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.green.opacity(0.12), in: .capsule)
                        .help(account.provider == .claude ? "New claude commands use this account" : "Codex on this Mac is signed in to this account")
                case .use:
                    Button("Use") { Task { await store.activate(account.id) } }
                case .none:
                    EmptyView()
                }
            }.frame(width: 64, alignment: .trailing)
            Menu {
                Button("Rename") { editing = true }
                Toggle("Include in Autopilot", isOn: Binding(get: { account.allowAuto }, set: { store.setAuto(account.id, $0) }))
                Picker("Use", selection: Binding(get: { account.priority ?? .normal }, set: { store.setPriority(account.id, $0) })) {
                    ForEach(AccountPriority.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if account.provider == .claude && account.ready {
                    Button("Open Terminal on \(account.name)") { Task { await store.openTerminal(account.id) } }
                }
                Divider()
                Button("Sign In Again") { Task { await store.signIn(account.id) } }.disabled(isActive)
                Button("Sign Out") { store.signOut(account.id) }.disabled(isActive || !account.ready)
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
        guard account.ready else { return store.signingIn.contains(account.id) ? account.email : "Not signed in" }
        let identity = account.email.isEmpty ? "Connected" : account.email
        if let issue = store.issueText(account.id) { return "\(identity) · \(issue)" }
        guard account.allowAuto else { return "\(identity) · Autopilot skips it" }
        return account.priority.flatMap { $0 == .normal ? nil : "\(identity) · Used \($0.title.lowercased())" } ?? identity
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
                let rhythm = store.report.flatMap { WeekRhythm($0.activity) }
                Section {
                    ForEach(weekly) { PaceRow(account: $0, usage: store.usage[$0.id]!, rhythm: rhythm) }
                } header: {
                    Text("This week")
                } footer: {
                    Text(outlook(weekly, rhythm: rhythm))
                }
            }
            let paying = store.config.accounts.filter { ($0.provider == .claude) && (store.usage[$0.id]?.extra.map { $0.enabled || $0.used > 0 } ?? false) }
            if !paying.isEmpty {
                Section {
                    ForEach(paying) { account in
                        let extra = store.usage[account.id]!.extra!
                        LabeledContent(account.name) {
                            Text(extra.enabled ? extra.summary : "Off · \(extra.summary)").monospacedDigit()
                        }
                    }
                } header: {
                    Text("Paid usage")
                }
            }
            if let report = store.report {
                Section {
                    HStack(spacing: 10) {
                        let days = Dictionary(report.days.map { ($0.date ?? "", $0.total) }, uniquingKeysWith: +)
                        let sum = { (range: ClosedRange<Int>) in range.reduce(0) { $0 + (days[MenuPlayer.day(-$1)] ?? 0) } }
                        // Early in the day, compare with what is usually used by this hour, not a whole day.
                        StatTile(title: "Today", value: sum(0...0), baseline: Double(sum(1...29)) / 29 * Self.shareOfDayByNow(report.activity),
                                 comparison: "usual by \(Date().formatted(.dateTime.hour()))")
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
                if let machines = report.machines, machines.count > 1 {
                    Section("Your Macs, last 7 days") {
                        let top = Double(max(machines.map(\.tokens).max() ?? 1, 1))
                        ForEach(machines, id: \.self) { machine in
                            HStack(spacing: 10) {
                                Text(machine.name + (machine.current ? " (this Mac)" : "")).lineLimit(1).frame(width: 170, alignment: .leading)
                                GeometryReader { proxy in
                                    Capsule().fill(machine.current ? Color.accentColor : Color.secondary.opacity(0.35))
                                        .frame(width: max(proxy.size.width * Double(machine.tokens) / top, 4))
                                }.frame(height: 8)
                                Text(TokenCount.short(machine.tokens)).monospacedDigit().frame(width: 56, alignment: .trailing)
                            }
                        }
                    }
                }
                let rows = report.dayModels ?? []
                Section {
                    DisclosureGroup("Projects") { shares(report.projects.prefix(6).map { (URL(fileURLWithPath: $0.project ?? "").lastPathComponent, $0.total) }) }
                    // Per agent, so a smaller Codex share is not crowded out by Claude.
                    ForEach(AgentProvider.allCases) { provider in
                        let models = report.models.filter { ModelName.provider($0.model) == provider }
                        if !models.isEmpty {
                            DisclosureGroup("\(provider.title) models") { shares(models.prefix(5).map { (ModelName.short($0.model), $0.total) }) }
                        }
                    }
                    if !rows.isEmpty {
                        DisclosureGroup("Worth at API prices") {
                            let week = rows.filter { ($0.date ?? "") >= MenuPlayer.day(-6) }
                            LabeledContent("Last 7 days") { Text(APIPrice.dollars(week), format: .currency(code: "USD").precision(.fractionLength(0))).monospacedDigit() }
                            LabeledContent("Last 30 days") { Text(APIPrice.dollars(rows), format: .currency(code: "USD").precision(.fractionLength(0))).monospacedDigit() }
                            let byModel = Dictionary(grouping: rows.filter { APIPrice.of($0.model) != nil }, by: { ModelName.short($0.model) })
                                .mapValues(APIPrice.dollars).sorted { $0.value > $1.value }.prefix(4)
                            ForEach(byModel, id: \.key) { model, dollars in
                                LabeledContent(model) { Text(dollars, format: .currency(code: "USD").precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary) }
                            }
                        }
                    }
                } header: {
                    Text("Details")
                }
            } else {
                Section {
                    HStack { ProgressView().controlSize(.small); Text("Reading transcripts…") }
                }
            }
        }
        .formStyle(.grouped)
        .task { await store.refreshReport() }
    }
    /// The week ahead across Claude accounts, each weighted by plan size and projected to its own reset.
    private func outlook(_ accounts: [Account], rhythm: WeekRhythm?) -> String {
        let now = Date().timeIntervalSince1970
        let claude = accounts.filter { $0.provider == .claude }.compactMap { account -> (Double, Double)? in
            guard let usage = store.usage[account.id], let weekly = usage.weekly else { return nil }
            let projected = WeekForecast(weekly, rhythm: rhythm, now: now)?.projected ?? weekly.percent
            return (min(projected, 100), usage.capacity ?? 1)
        }
        let capacity = claude.reduce(0) { $0 + $1.1 }
        guard capacity > 0 else { return "" }
        let share = claude.reduce(0) { $0 + $1.0 * $1.1 } / capacity
        let basis = rhythm == nil ? "at this week's pace" : "at your usual weekly rhythm"
        let pace = share >= 99.5 ? "on pace to use all of your combined Claude limits before they reset" : "on pace to use \(Int(share))% of your combined Claude limits"
        return "Week ahead: \(pace), \(basis). The tick on each bar is where you would usually be by now."
    }
    /// Share of a typical day's activity that happens before this moment, from past days' hourly counts.
    static func shareOfDayByNow(_ activity: [ActivitySpan]) -> Double {
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let hour = now.hour ?? 0, part = Double(now.minute ?? 0) / 60
        let past = activity.filter { $0.date != MenuPlayer.day(0) }
        let total = past.reduce(0.0) { $0 + Double($1.hours.reduce(0, +)) }
        guard total > 0 else { return 1 }
        let done = past.reduce(0.0) { sum, span in
            sum + Double(span.hours.prefix(hour).reduce(0, +)) + (span.hours.indices.contains(hour) ? Double(span.hours[hour]) * part : 0)
        }
        return max(done / total, 0.02)
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
    let usage: AccountUsage
    let rhythm: WeekRhythm?
    private var window: UsageWindow { usage.weekly! }
    var body: some View {
        let used = window.used(at: Date().timeIntervalSince1970)
        let forecast = WeekForecast(window, rhythm: rhythm, now: Date().timeIntervalSince1970)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(account.name).font(.body.weight(.medium))
                Text(account.provider.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(verdict(used: used, forecast: forecast)).font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(used >= Planner.limited ? Color.red : .accentColor).frame(width: proxy.size.width * used / 100)
                    // Where usage would be by now if this week follows your usual rhythm.
                    Rectangle().fill(.primary.opacity(0.55)).frame(width: 1.5, height: 10).offset(x: proxy.size.width * (forecast?.expectedNow ?? 0) - 0.75)
                }
            }.frame(height: 6)
            Text(LimitText.resets(usage)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
    private func verdict(used: Double, forecast: WeekForecast?) -> String {
        guard let reset = window.resetsAt, reset > Date().timeIntervalSince1970 else { return "\(Int(used.rounded()))% used" }
        if used >= Planner.limited { return "Limited, back \(UsageBar.format(reset))" }
        guard let forecast, forecast.projected > used else { return "\(Int(used.rounded()))% used, resets \(UsageBar.format(reset))" }
        if let out = forecast.runsOut { return "Runs out \(UsageBar.format(out))" }
        return "On pace for \(Int(forecast.projected))% by \(UsageBar.format(reset))"
    }
}

/// Plain-words limit summaries shared by the Usage and Accounts tabs.
enum LimitText {
    /// "Fable" for "Weekly Fable".
    static func name(_ window: UsageWindow) -> String {
        window.label.hasPrefix("Weekly ") ? String(window.label.dropFirst("Weekly ".count)) : window.label
    }
    /// Every window's reset, e.g. "5-hour 24%, resets in 2h 10m · Fable 0%, resets Sat 5 PM".
    static func resets(_ usage: AccountUsage) -> String {
        let now = Date().timeIntervalSince1970
        let live = { (window: UsageWindow?) in window.flatMap { ($0.resetsAt ?? 0) > now ? $0 : nil } }
        var parts: [String] = []
        if let five = live(usage.fiveHour) { parts.append("5-hour \(five.text(at: now)), resets \(UsageBar.format(five.resetsAt!))") }
        else if usage.fiveHour != nil { parts.append("5-hour idle") }
        let weekly = live(usage.weekly).map { "week resets \(UsageBar.format($0.resetsAt!))" }
        if let weekly { parts.append(weekly) }
        for limit in usage.modelLimits {
            parts.append("\(name(limit)) \(limit.text(at: now))\(live(limit).map { ", resets \(UsageBar.format($0.resetsAt!))" } ?? "")")
        }
        return parts.joined(separator: " · ")
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
    /// Which agent produced a model id: Claude ids name Claude or a Claude family, anything else is Codex.
    static func provider(_ id: String?) -> AgentProvider {
        let id = (id ?? "").lowercased()
        return ["claude", "opus", "sonnet", "haiku", "fable"].contains(where: id.contains) ? .claude : .codex
    }
    /// "claude-opus-5-5-20260101" reads as "Opus 5.5".
    static func short(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "Other" }
        if id.hasPrefix("gpt-") {
            // "gpt-6.1-sol" reads as "GPT-6.1 Sol".
            let parts = id.dropFirst(4).split(separator: "-").map(String.init)
            return "GPT-" + (parts.first ?? "") + parts.dropFirst().map { " " + $0.capitalized }.joined()
        }
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
                    Text("Autopilot").font(.headline)
                    Text(status)
                }
                Picker(selection: Binding(get: { store.config.moveAt }, set: { store.setSwapAt($0) })) {
                    ForEach(SwapAtChange.choices.map { Double($0) }, id: \.self) { Text("\(Int($0))%").tag($0) }
                } label: {
                    Text("Move at")
                }
                Toggle("Follow Fable", isOn: Binding(get: { store.config.followFable != false }, set: { store.setFollowFable($0) }))
                Toggle(isOn: Binding(get: { store.config.pool == true }, set: { value in Task { await store.setPool(value) } })) {
                    Text("Pool mode")
                    Text(poolStatus)
                }
                if store.config.pool == true || store.remotePool != nil {
                    PoolHealthRows(store: store)
                }
                if store.config.pool == true {
                    Toggle(isOn: Binding(get: { store.config.poolShare == true }, set: { value in Task { await store.setPoolShare(value) } })) {
                        Text("Share with my other Macs")
                        Text(store.poolShareProblem ?? "Over Tailscale, only to devices signed in to Tailscale as you. Sign in to your accounts here once; on each other Mac, run this in Terminal:")
                    }
                    if let command = store.poolShareCommand {
                        HStack {
                            Text(command).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            }
                            Button("New Key") { Task { await store.newPoolShareKey() } }
                                .help("Macs that joined stop using this one until they run the new command.")
                        }
                    }
                }
            }
            Section {
                Toggle("Answer with recommended after 1 minute",
                       isOn: Binding(get: { store.config.answerRecommended == true }, set: { store.setAnswerRecommended($0) }))
            }
            Section {
                UpNext(store: store)
            } header: {
                Text(store.fableMode ? "Up next for Fable" : "Up next")
            }
            Section("Your day") {
                DayTimeline(store: store)
            }
        }.formStyle(.grouped)
    }

    private var poolStatus: String {
        guard store.config.pool == true else {
            return "Claude Code and Codex in Terminal send their requests through Side A, which keeps each conversation on one account and moves it the moment that one is full. Logins never leave this Mac. Anthropic doesn't support this setup."
        }
        switch store.poolRun {
        case .off, .starting: return "Starting…"
        case .failed(let why): return "Couldn't start: \(why) Turn it off and on again to retry."
        case .running: break
        }
        let conversations = store.poolConversations.values.reduce(0, +)
        return "On. \(conversations) conversation\(conversations == 1 ? "" : "s") in the last hour, on \(store.poolConversations.count) account\(store.poolConversations.count == 1 ? "" : "s"). New terminal commands use it; sidea use <name> keeps a tab on one account."
    }

    private var status: String {
        guard store.config.smartMode else { return "Off. Side A only shows your limits." }
        guard store.shellSwitching else { return "On, but it can't move Terminal to another account until Switch in Terminal is on, in Setup." }
        let using = store.active.map { "Using \($0.name)\(store.fableMode ? " for Fable" : "")" } ?? "Watching your accounts"
        guard let schedule = store.schedule else { return "\(using). Learning your hours." }
        return "\(using). Warms up idle windows from \(TokenCount.clock(schedule.start - WorkSchedule.lead))."
    }
}

/// What is left across the pool, what it last did, and a check of every login that spends no quota.
struct PoolHealthRows: View {
    @Bindable var store: AccountStore

    var body: some View {
        let now = Date().timeIntervalSince1970
        if store.config.pool == true {
            ForEach(AgentProvider.allCases) { provider in
                let members = store.poolMembers(provider)
                if let room = PoolRoom(members, usage: provider == .claude ? store.planning(store.usage) : store.usage, full: store.config.moveAt, now: now) {
                    LabeledContent(provider.title) {
                        Text(Self.summary(room)).multilineTextAlignment(.trailing)
                    }
                }
                if let activity = store.poolHealth[provider], let line = Self.line(activity, now: now) {
                    Text(line).font(.caption).foregroundStyle(activity.failing ? .red : .secondary)
                }
            }
        }
        if let remote = store.remotePool {
            LabeledContent("Another Mac's pool") {
                Text(remote.detail).multilineTextAlignment(.trailing).foregroundStyle(remote.answered == false ? .red : .secondary)
            }
        }
        LabeledContent("Check logins") {
            if store.poolTesting { ProgressView().controlSize(.small) } else {
                Button("Test Pool") { Task { await store.testPool() } }
                    .help("Checks each account's login the way a request would. No model runs and no quota is used.")
            }
        }
        if let results = store.poolTest {
            ForEach(store.config.accounts.filter { results[$0.id] != nil }) { account in
                LabeledContent("\(account.name) · \(account.provider.title)") {
                    Text(results[account.id]!).foregroundStyle(results[account.id] == "Ready" ? .green : .red)
                }
            }
        }
    }

    private static func summary(_ room: PoolRoom) -> String {
        var parts = room.fiveHourLeft.map { ["5-hour \(Int($0))% left"] } ?? []
        parts += ["week \(Int(room.weeklyLeft))% left", "\(room.accounts) account\(room.accounts == 1 ? "" : "s")"]
        if room.limited > 0 { parts.append("\(room.limited) full") }
        if let refill = room.refill { parts.append("\(refill.name) back \(UsageBar.format(refill.at))") }
        return parts.joined(separator: " · ")
    }

    private static func line(_ activity: PoolActivity, now: Double) -> String? {
        if activity.failing, let failure = activity.failure { return "Last request refused: \(failure)" }
        guard let at = activity.servedAt, let name = activity.servedBy else { return nil }
        let minutes = Int((now - at) / 60)
        return "Last answer \(minutes < 1 ? "just now" : "\(minutes) min ago") from \(name)."
    }
}

/// Claude accounts ranked the way Autopilot ranks them, with the score that decides.
struct UpNext: View {
    @Bindable var store: AccountStore
    var body: some View {
        let now = Date().timeIntervalSince1970
        let usage = store.planning(store.usage)
        let ranked = store.config.accounts.filter { $0.provider == .claude && $0.ready && $0.allowAuto }
            .compactMap { account in usage[account.id].map { (account, $0, Planner.urgency($0, now: now)) } }
            .sorted { $0.2 > $1.2 }
        let top = max(ranked.first?.2 ?? 1, 0.01)
        let pick = Planner.best(store.config.accounts.filter { $0.provider == .claude }, usage: usage, health: store.health, active: store.activeIDs[.claude], full: store.config.moveAt, now: now)
        if ranked.isEmpty {
            Text("Add Claude accounts to see how Autopilot ranks them.").foregroundStyle(.secondary)
        }
        ForEach(ranked, id: \.0.id) { account, usage, score in
            HStack(spacing: 10) {
                Text(account.name).font(.body.weight(account.id == pick ? .semibold : .regular)).frame(width: 110, alignment: .leading).lineLimit(1)
                GeometryReader { proxy in
                    Capsule().fill(account.id == pick ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: max(proxy.size.width * score / top, 4))
                }.frame(height: 8)
                Text(score < 0.05 ? "–" : String(format: "%.1f/h", score)).font(.custom("Noteworthy-Bold", size: 13)).monospacedDigit().frame(width: 52, alignment: .trailing)
                Text(account.id == pick ? (store.activeIDs[.claude] == account.id ? "In use" : "Next") : Planner.hasHeadroom(usage, full: store.config.moveAt, now: now) ? "" : "Limited")
                    .font(.caption.weight(.medium)).foregroundStyle(account.id == pick ? .green : .secondary).frame(width: 48, alignment: .trailing)
            }
        }
    }
}

/// The learned working day on a 24-hour strip: activity, working hours, warm-up start and now.
struct DayTimeline: View {
    @Bindable var store: AccountStore
    var body: some View {
        let activity = store.report?.activity ?? []
        let hours = (0..<24).map { hour in activity.reduce(0) { $0 + ($1.hours.indices.contains(hour) ? $1.hours[hour] : 0) } }
        let peak = Double(max(hours.max() ?? 0, 1))
        let schedule = store.schedule
        let calendar = Calendar.current
        let nowMinute = calendar.component(.hour, from: Date()) * 60 + calendar.component(.minute, from: Date())
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let x = { (minute: Int) in proxy.size.width * CGFloat(((minute % 1440) + 1440) % 1440) / 1440 }
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 1.5) {
                        ForEach(0..<24, id: \.self) { hour in
                            RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.08 + 0.7 * Double(hours[hour]) / peak))
                        }
                    }
                    if let schedule {
                        // Working hours, outlined; may wrap past midnight.
                        let start = x(schedule.start), end = x(schedule.end)
                        Group {
                            if end > start {
                                RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1.5).frame(width: end - start).offset(x: start)
                            } else {
                                RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1.5).frame(width: proxy.size.width - start).offset(x: start)
                                RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1.5).frame(width: end)
                            }
                        }
                        Image(systemName: "sunrise.fill").font(.system(size: 11)).foregroundStyle(.orange)
                            .position(x: x(schedule.start - WorkSchedule.lead), y: -9)
                    }
                    Rectangle().fill(.primary).frame(width: 1.5, height: proxy.size.height + 6).offset(x: x(nowMinute), y: -3)
                }
            }
            .frame(height: 26).padding(.top, 14)
            HStack {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(TokenCount.clock(hour * 60)).font(.caption2).foregroundStyle(.secondary)
                    if hour != 18 { Spacer() }
                }
                Spacer()
            }
            Text(schedule.map { "You usually work \(TokenCount.clock($0.start))–\(TokenCount.clock($0.end)). Idle 5-hour windows start from \(TokenCount.clock($0.start - WorkSchedule.lead)), so they reset sooner." }
                 ?? "Learning your hours from a week of activity.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct GeneralSettings: View {
    @Bindable var store: AccountStore
    @ObservedObject var updates: Updates
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("tourSeen") private var tourSeen = false
    @AppStorage(MenuPlayer.enabledKey) private var playerEnabled: Bool = PreferencesMirror.fallback(MenuPlayer.enabledKey)
    @State private var indexBytes: Int64 = 0
    @State private var rebuilding = false
    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: { store.setLaunchAtLogin($0); launchAtLogin = SMAppService.mainApp.status == .enabled }))
                Toggle("Show only in the menu bar", isOn: Binding(get: { store.config.menuBarOnly }, set: { store.setMenuBarOnly($0) }))
                Toggle("3D player", isOn: $playerEnabled)
            }
            KeepAwakeSettings(keepAwake: store.keepAwake)
            Section {
                Toggle(isOn: Binding(get: { store.config.sync == true }, set: { store.setSync($0) })) {
                    Text("Sync with your other Macs")
                    Text(store.syncFolder == nil ? "Turn on iCloud Drive to combine usage across your Macs."
                         : "Usage, working hours, accounts and settings through iCloud Drive. Logins stay on each Mac.")
                }.disabled(store.syncFolder == nil && store.config.sync != true)
            }
            Section("Updates") {
                Toggle("Update Automatically", isOn: $updates.automaticallyUpdates)
                LabeledContent { UpdateButton(updates: updates) } label: {
                    Text("Side A \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                }
            }
            Section("Session search") {
                LabeledContent {
                    if rebuilding { ProgressView().controlSize(.small) }
                    else {
                        Button("Rebuild") {
                            rebuilding = true
                            Task { await store.sessions.rebuildIndex(); indexBytes = store.sessions.indexBytes; rebuilding = false }
                        }
                    }
                } label: {
                    Text("Search index")
                    Text(rebuilding ? "Reading your conversations again…" : "\(indexBytes.formatted(.byteCount(style: .file))) on this Mac, built from your transcripts")
                }
            }
            Section("Privacy") {
                UsagePreference(analytics: store.analytics)
                LabeledContent {
                    Button("Save Diagnostics…") { store.saveDiagnostics(updateError: updates.failure) }
                } label: { Link("Privacy details", destination: URL(string: "https://getsidea.com/index.md")!) }
            }
            Section {
                LabeledContent("Guided tour") { Button("Show Again") { tourSeen = false } }
                LabeledContent {
                    Button("Remove…", role: .destructive) { confirmUninstall() }
                } label: {
                    Text("Remove Side A")
                    Text("Undoes its shell line, statusline and hooks, and moves it to the Trash.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { indexBytes = store.sessions.indexBytes }
    }

    private func confirmUninstall() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove Side A?"
        alert.informativeText = "Side A takes its line out of ~/.zshrc, restores your Claude Code statusline and hooks, stops opening at login, deletes its caches and search index, and moves itself to the Trash. Your conversations aren't touched, and your accounts and their logins stay unless you choose otherwise."
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Also sign out of and forget my accounts"
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let forget = alert.suppressionButton?.state == .on
        Task { await store.uninstall(forgetAccounts: forget) }
    }
}

/// Everything that can interrupt you: the notch, banners and sounds.
struct NotificationSettings: View {
    @Bindable var store: AccountStore
    @AppStorage(Sounds.enabledKey) private var sounds: Bool = PreferencesMirror.fallback(Sounds.enabledKey)
    @AppStorage(Sounds.volumeKey) private var volume: Double = PreferencesMirror.fallback(Sounds.volumeKey)
    @AppStorage(WaitingNotifier.enabledKey) private var notifyWaiting: Bool = PreferencesMirror.fallback(WaitingNotifier.enabledKey)
    @AppStorage(AccountStore.weeklyAlertKey) private var weeklyAlert: Double = PreferencesMirror.fallback(AccountStore.weeklyAlertKey)

    var body: some View {
        Form {
            IslandSettings(store: store)
            Section {
                Toggle("A session needs you", isOn: $notifyWaiting)
                .onChange(of: notifyWaiting) {
                    if notifyWaiting { WaitingNotifier.requestPermission() }
                    store.startNotifications()
                }
                Picker("An account's week passes", selection: $weeklyAlert) {
                    Text("Off").tag(0.0)
                    ForEach([50.0, 75.0, 80.0, 90.0], id: \.self) { Text("\(Int($0))%").tag($0) }
                }
            } header: {
                Text("Banners")
            }
            Section("Sound") {
                Toggle("Sound effects", isOn: $sounds)
                if sounds {
                    LabeledContent("Volume") {
                        Slider(value: $volume, in: 0.1...1) { editing in if !editing { Sounds.play(.trackChange) } }
                            .frame(width: 160)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct KeepAwakeSettings: View {
    @Bindable var keepAwake: KeepAwakeController

    var body: some View {
        Section {
            Toggle("Keep awake while agents work", isOn: Binding(get: { keepAwake.settings.enabled }, set: { keepAwake.setEnabled($0) }))
            if keepAwake.settings.enabled && keepAwake.offersLid || keepAwake.settings.lidClosed || keepAwake.busy {
                Toggle("Also with the lid closed", isOn: Binding(get: { keepAwake.settings.lidClosed }, set: { value in Task { await keepAwake.setLidClosed(value) } }))
                    .disabled(keepAwake.busy)
                if keepAwake.settings.lidClosed {
                    HelperApproval(keepAwake: keepAwake)
                    Toggle("Also on battery", isOn: Binding(get: { keepAwake.settings.onBattery }, set: { keepAwake.setOnBattery($0) }))
                }
            }
        } footer: {
            if let error = keepAwake.error {
                Text(error).foregroundStyle(.red)
            }
        }
    }
}

/// System Settings is where the user approves the helper, so the row follows its status while it waits.
private struct HelperApproval: View {
    var keepAwake: KeepAwakeController

    var body: some View {
        Group {
            switch keepAwake.helper {
            case .ready:
                Label("Approved in Login Items", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .needsApproval:
                HStack {
                    Label("Needs a one-time approval in Login Items.", systemImage: "lock.circle")
                    Spacer()
                    Button("Open Login Items") { keepAwake.openLoginItems() }
                }
            case .off:
                HStack {
                    Label("Side A's helper is off.", systemImage: "exclamationmark.circle")
                    Spacer()
                    Button("Turn On") { Task { await keepAwake.setLidClosed(true) } }
                }
            case .unavailable:
                Label("Only Side A in Applications can do this.", systemImage: "exclamationmark.circle")
            }
        }
        .font(.callout)
        .task(id: keepAwake.helper) {
            keepAwake.refreshHelper()
            while keepAwake.helper == .needsApproval, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                keepAwake.refreshHelper()
            }
        }
    }
}

struct IslandSettings: View {
    @Bindable var store: AccountStore
    @AppStorage(Island.onKey) private var on: Bool = PreferencesMirror.fallback(Island.onKey)
    @AppStorage(Island.eventsKey) private var events: Bool = PreferencesMirror.fallback(Island.eventsKey)
    @AppStorage(Island.waitingKey) private var waiting: Bool = PreferencesMirror.fallback(Island.waitingKey)
    @AppStorage(Island.finishedKey) private var finished: Bool = PreferencesMirror.fallback(Island.finishedKey)
    @AppStorage(Island.finishedClearKey) private var clearFinished: Int = PreferencesMirror.fallback(Island.finishedClearKey)
    @AppStorage(Island.finishedAutomatedKey) private var finishedAutomated: Bool = PreferencesMirror.fallback(Island.finishedAutomatedKey)
    @AppStorage(Island.screenKey) private var screen: String = PreferencesMirror.fallback(Island.screenKey)
    @State private var showingKeys = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { on }, set: { value in
                on = value
                // Remote keeps the hooks; only the notch goes.
                if value || !RemoteController.active { Task { await store.setIsland(value ? .claude : nil, value ? "on" : "off") } }
                store.startNotifications()
            })) {
                Text("Dynamic Island")
            }
            if on {
                Toggle("Claude Code requests", isOn: hook(.claude))
                Toggle(isOn: hook(.codex)) {
                    Text("Codex requests")
                    Text("Approve the hook once with /hooks in Codex.")
                }
                Toggle("Sessions that finish", isOn: $finished)
                if finished {
                    Toggle("Include automated runs", isOn: $finishedAutomated)
                    Picker("Clear finished sessions", selection: $clearFinished) {
                        Text("Never").tag(0)
                        Text("After 30 seconds").tag(30)
                        Text("After 1 minute").tag(60)
                        Text("After 5 minutes").tag(300)
                    }
                }
                Toggle("Account changes and limits", isOn: $events)
                Toggle("Sessions waiting for you", isOn: $waiting)
                    .onChange(of: waiting) { store.startNotifications() }
                Picker("Show on", selection: $screen) {
                    Text("The display with the notch").tag("notch")
                    Text("The display with the pointer").tag("active")
                }
                LabeledContent("Shortcuts") {
                    Button("Show Shortcuts") { showingKeys = true }
                        .popover(isPresented: $showingKeys, arrowEdge: .trailing) { IslandShortcuts() }
                }
                LabeledContent("Try it") { Button("Show Sample Request") { store.island.preview() } }
            }
        }
    }

    private func hook(_ agent: IslandAgent) -> Binding<Bool> {
        Binding(get: { store.island.installed[agent] == true },
                set: { value in Task { await store.setIsland(agent, value ? "on" : "off") } })
    }
}

private struct IslandShortcuts: View {
    private static let keys = [("⌃⌥Y", "Allow"), ("⌃⌥N", "Deny"), ("⌃⌥A", "Always allow"), ("⌃⌥1–4", "Answer a question"),
                               ("⌃⌥G", "Go to the session that's done"), ("⌃⌥R", "Reply with its next task"), ("⌃⌥I", "Focus the island"),
                               ("⌃⌥T", "Show the terminal"), ("⌃⌥← →", "Switch requests")]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(Self.keys, id: \.0) { key, action in
                GridRow {
                    Text(key).font(.system(size: 12).monospaced()).foregroundStyle(.secondary)
                    Text(action)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
    }
}
