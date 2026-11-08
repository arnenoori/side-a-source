import SideACore
import SwiftUI

/// The menu bar is Side A's home: usage for every account and the Mac-wide login.
struct MenuPlayer: View {
    /// Local calendar date `offset` days from today, in the report's yyyy-MM-dd form.
    static func day(_ offset: Int) -> String {
        Date.ISO8601FormatStyle(timeZone: .current).year().month().day().format(Calendar.current.date(byAdding: .day, value: offset, to: Date())!)
    }
    @Bindable var store: AccountStore
    @ObservedObject var updates: Updates
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL
    @AppStorage("tourSeen") private var tourSeen = false
    static let enabledKey = "playerEnabled"
    @AppStorage(MenuPlayer.enabledKey) private var playerEnabled: Bool = PreferencesMirror.fallback(MenuPlayer.enabledKey)
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Side A").font(.headline)
                Spacer()
                Button { Task { await store.refreshAll(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh usage")
            }
            statusLine
            ForEach(AgentProvider.allCases) { provider in
                if let email = store.loginsToAdd[provider] {
                    HStack {
                        Text("\(provider.title) on this Mac: \(email)").font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Add") { Task { await store.adoptMacLogin(provider) } }.controlSize(.small)
                    }
                }
            }
            if store.config.accounts.isEmpty {
                HStack {
                    Text("Add an account to see its limits.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.openLibrary() } label: { Label("Add account", systemImage: "plus") }
                        .controlSize(.small).tourAnchor(.add)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(AgentProvider.allCases) { provider in
                        ProviderSection(store: store, provider: provider, firstID: store.config.accounts.first?.id)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            if store.unknownLogins[.claude] == nil, let next = Planner.nextAvailable(store.config.accounts.filter { $0.provider == .claude }, usage: store.usage, full: store.config.moveAt, now: Date().timeIntervalSince1970),
               Planner.best(store.config.accounts.filter { $0.provider == .claude }, usage: store.usage, health: store.health, active: nil, full: store.config.moveAt, now: Date().timeIntervalSince1970) == nil {
                Text("All limited. \(next.0.name) is back \(UsageBar.format(next.1)).")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(4)
                    .onTapGesture { store.error = nil }
            }
            if let version = updates.available {
                Button { updates.install() } label: {
                    Label("Update to \(version)", systemImage: "arrow.down.circle.fill").font(.system(size: 11, weight: .medium))
                }.buttonStyle(.borderless).disabled(!updates.canUpdate).help("Restart Side A with the new version")
            } else if let version = updates.updated() {
                Link(destination: UpdateHistory.notes(version)) {
                    Label("Updated to \(version)", systemImage: "checkmark.circle").font(.system(size: 11, weight: .medium))
                }.buttonStyle(.borderless).foregroundStyle(.secondary).help("What's new in \(version)")
            }
            if updates.failure != nil {
                Link(destination: URL(string: "https://getsidea.com")!) {
                    Label("Update didn't install · Download it", systemImage: "exclamationmark.arrow.circlepath").font(.system(size: 11, weight: .medium))
                }.help("Download the latest Side A and replace this copy")
            }
            Divider()
            // Autopilot is on unless turned off in Settings > Autopilot, so the footer carries usage instead of its switch.
            HStack(spacing: 0) {
                usage
                Spacer(minLength: 10)
                HStack(spacing: 14) {
                    if playerEnabled {
                        Button { openPlayer() } label: { Image(systemName: "opticaldisc") }.help("Show the player").accessibilityLabel("Show the player")
                    }
                    Button { openSessions() } label: { Image(systemName: "text.bubble") }.help("Sessions").accessibilityLabel("Sessions")
                    Button { store.openSettings() } label: { Image(systemName: "gearshape") }
                        .help("Settings").accessibilityLabel("Settings")
                        .modifier(TourAnchorIf(step: .add, active: !store.config.accounts.isEmpty))
                    Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit Side A").accessibilityLabel("Quit Side A")
                }
            }.buttonStyle(.borderless).font(.system(size: 12))
        }.padding(16).frame(width: 320)
        .guidedTour(isPresented: Binding(get: { !tourSeen && !store.isDemo }, set: { if !$0 { tourSeen = true } }))
        .task { await store.refreshAll() }
        .onAppear {
            store.showSettings = { openSettings() }
            store.showSessions = { openWindow(id: "sessions") }
        }
    }
    /// "Today 905.7M · 7 days 28.3B", opening Settings > Usage.
    @ViewBuilder private var usage: some View {
        if let report = store.report, !report.days.isEmpty {
            // Calendar days: an idle day counts as zero, not as the last active day.
            let today = report.days.first { $0.date == Self.day(0) }?.total ?? 0
            let week = report.days.filter { ($0.date ?? "") >= Self.day(-6) }.map(\.total).reduce(0, +)
            Button { store.settingsTab = .usage; store.openSettings() } label: {
                HStack(spacing: 4) {
                    Text("Today \(TokenCount.short(today))")
                    Text("· 7 days \(TokenCount.short(week))").foregroundStyle(.secondary)
                }.font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8).contentShape(.rect)
            }.buttonStyle(.plain).layoutPriority(1).help("Tokens by day, project and model").tourAnchor(.usage)
            .accessibilityLabel("Usage: today \(TokenCount.short(today)), 7 days \(TokenCount.short(week))")
            .accessibilityHint("Opens Usage in Settings")
        }
    }

    /// One line at most, so the menu never stacks banners; the rest stay visible in Sessions.
    @ViewBuilder private var statusLine: some View {
        let waiting = store.island.pending.count, finished = store.island.ready.count
        if waiting > 0 {
            status("hand.raised.fill", .orange, finished > 0 ? "\(waiting) waiting for you · \(finished) finished" : "\(waiting) waiting for you",
                   help: "Answer or reply in Sessions", action: openSessions)
        } else if let warning = store.memoryWarning {
            status("memorychip", .orange, warning,
                   help: "macOS reports memory pressure. See what each session holds and quit idle ones in Sessions.", action: openSessions)
        } else if let outage = store.outage {
            status("exclamationmark.icloud", outage.major ? .red : .orange, "Claude: \(outage.name)",
                   help: "Open status.claude.com. Errors in sessions right now may be Anthropic's, not your accounts'.") { openURL(AccountStore.statusPage) }
        } else if finished > 0 {
            status("checkmark.circle.fill", .green, "\(finished) finished", help: "Reply in Sessions", action: openSessions)
        } else if let awake = store.keepAwake.line {
            status("cup.and.saucer.fill", .secondary, awake, help: "Keep awake while agents work, in Settings > General",
                   label: store.keepAwake.accessibilityLine) { store.settingsTab = .general; store.openSettings() }
                .foregroundStyle(.secondary)
        } else if !store.config.smartMode {
            status("pause.circle", .secondary, "Autopilot is off", help: "Turn it on in Settings > Autopilot") {
                store.settingsTab = .autopilot; store.openSettings()
            }.foregroundStyle(.secondary)
        }
    }
    private func status(_ symbol: String, _ tint: Color, _ text: String, help: String, label: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(text).lineLimit(2)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .font(.system(size: 11, weight: .medium)).contentShape(.rect)
        }
        .buttonStyle(.plain).help(help)
        .accessibilityLabel(label ?? text)
    }
    /// Opens the conversation that waits longest on you, else the one that finished last.
    private func openSessions() {
        store.openSessions(store.island.pending.first?.request.sessionID ?? store.island.ready.first?.finish.sessionID)
    }
    private func openPlayer() { store.playerRequested = true; openWindow(id: "player"); NSApp.activate(ignoringOtherApps: true) }
}

/// One provider's accounts. Accounts at their weekly limit fold away until they reset.
struct ProviderSection: View {
    @Bindable var store: AccountStore
    let provider: AgentProvider
    let firstID: String?
    @State private var showLimited = false

    var body: some View {
        let accounts = store.config.accounts.filter { $0.provider == provider }
        let now = Date().timeIntervalSince1970
        let limited = accounts.filter { account in
            !store.isActive(account) && (store.usage[account.id]?.weekly).map { $0.percent >= Planner.limited && ($0.resetsAt ?? 0) > now } == true
        }
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(provider.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(accounts.filter { account in !limited.contains { $0.id == account.id } }) { account in
                    AccountUsageRow(store: store, account: account)
                        .modifier(TourAnchorIf(step: .limits, active: account.id == firstID))
                }
                if !limited.isEmpty {
                    // Instant: an animated height resizes the menu window every frame and flashes the scroller.
                    Button { showLimited.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right").rotationEffect(.degrees(showLimited ? 90 : 0))
                                .animation(.easeOut(duration: 0.15), value: showLimited)
                            Text("Limited (\(limited.count))")
                            if let reset = limited.compactMap({ store.usage[$0.id]?.weekly?.resetsAt }).min() {
                                Text("· next back \(UsageBar.format(reset))").foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.font(.system(size: 11)).contentShape(.rect)
                    }.buttonStyle(.plain)
                    if showLimited {
                        ForEach(limited) { AccountUsageRow(store: store, account: $0) }
                    }
                }
            }
        }
    }
}

struct AccountUsageRow: View {
    @Bindable var store: AccountStore
    let account: Account
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in row }
    }
    private var row: some View {
        let isActive = store.isActive(account)
        let usage = store.usage[account.id]
        return HStack(spacing: 8) {
            Circle().fill(isActive ? Color.green : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                .accessibilityLabel(isActive ? "Active on this Mac" : "Not active")
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name).font(.system(size: 12, weight: isActive ? .semibold : .regular)).lineLimit(1)
                if let caption { Text(caption).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if let usage {
                // With the week used up nothing else can be spent until it resets, so only the week shows.
                let weekFull = (usage.weekly?.used(at: Date().timeIntervalSince1970) ?? 0) >= Planner.limited
                if !weekFull {
                    MiniBar(label: "5h", window: usage.fiveHour)
                    // A model's own weekly cap only earns space once that model has been used.
                    ForEach(usage.modelLimits.filter { $0.percent >= 1 }, id: \.id) { limit in
                        MiniBar(label: String(limit.label.dropFirst("Weekly ".count).prefix(2)).lowercased(), window: limit)
                            .help(limit.label)
                    }
                }
                MiniBar(label: "wk", window: usage.weekly)
            }
            Group {
                switch store.rowAction(for: account) {
                case .busy:
                    ProgressView().controlSize(.mini)
                case .signIn:
                    Button("Sign in") { Task { await store.signIn(account.id) } }
                case .renew:
                    Button("Renew") { Task { await store.wake(account.id) } }
                        .disabled(store.waking.contains(account.id))
                        .help("Has Claude Code renew this login; no model runs and no quota is used")
                case .use:
                    Button("Use") { Task { await store.activate(account.id) } }.tourAnchor(.use)
                        .help("New claude commands use this account")
                case .inUse, .none:
                    Color.clear
                }
            }.controlSize(.mini).frame(width: 44)
        }
        .frame(minHeight: 28)
        .contextMenu {
            if !isActive && account.ready && account.provider == .claude { Button("Use") { Task { await store.activate(account.id) } } }
            if account.ready && account.provider == .claude { Button("Open Terminal on \(account.name)") { Task { await store.openTerminal(account.id) } } }
            if !isActive { Button("Sign In Again") { Task { await store.signIn(account.id) } } }
            Button("Settings…") { store.settingsTab = .accounts; store.openSettings() }
        }
    }

    private var caption: String? {
        guard account.ready else { return store.signingIn.contains(account.id) ? nil : "Not signed in" }
        if let issue = store.issueText(account.id) { return issue }
        guard let usage = store.usage[account.id] else { return "Reading…" }
        if usage.stale { return "Sign in again" }
        if let minutes = store.minutesToLimit(account.id), minutes < 300 { return "Limit in ~\(Self.duration(minutes))" }
        let now = Date().timeIntervalSince1970
        if let blocked = [usage.fiveHour, usage.weekly].compactMap({ $0 }).filter({ $0.percent >= Planner.limited && ($0.resetsAt ?? 0) > now }).compactMap(\.resetsAt).max() {
            if let extra = usage.extra, extra.enabled { return "Charging paid credits · \(extra.money(extra.used)) this month" }
            return "Back \(UsageBar.format(blocked))"
        }
        return nil
    }
}

/// A compact labeled meter; the reset time is in the tooltip.
struct MiniBar: View {
    let label: String
    let window: UsageWindow?
    /// Shows when the window resets under the bar instead of only in the tooltip.
    var showsReset = false
    var body: some View {
        let now = Date().timeIntervalSince1970
        let percent = window?.used(at: now) ?? 0
        VStack(alignment: .trailing, spacing: 2) {
            Text(window.map { "\(label) \($0.text(at: now))" } ?? "\(label) –")
                .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
            Capsule().fill(.quaternary).frame(width: 46, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(percent >= Planner.limited ? Color.red : percent >= 75 ? .orange : .accentColor)
                        .frame(width: 46 * percent / 100, height: 4)
                }
            if showsReset {
                Text(window?.resetsAt.flatMap { $0 > Date().timeIntervalSince1970 ? UsageBar.format($0).replacingOccurrences(of: "in ", with: "") : nil } ?? " ")
                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .help(window?.resetsAt.flatMap { $0 > now ? "\(window?.label ?? label) resets \(UsageBar.format($0))" : nil } ?? "")
        .accessibilityElement(children: .combine)
    }
}

extension AccountUsageRow {
    static func duration(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        return total >= 60 ? "\(total / 60)h \(total % 60)m" : "\(total)m"
    }
}

struct UsageBar: View {
    let window: UsageWindow
    var body: some View {
        let now = Date().timeIntervalSince1970
        let percent = window.used(at: now)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(window.label).font(.system(size: 10))
                Spacer()
                Text(window.text(at: now)).font(.system(size: 10).monospacedDigit())
                if let reset = window.resetsAt, reset > now {
                    Text("· resets \(Self.format(reset))").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: percent, total: 100).progressViewStyle(.linear)
                .tint(percent >= Planner.limited ? .red : percent >= 75 ? .orange : .accentColor)
        }.accessibilityElement(children: .combine)
    }
    static func format(_ reset: Double) -> String {
        let date = Date(timeIntervalSince1970: reset)
        let seconds = date.timeIntervalSinceNow
        if seconds < 24 * 3600 {
            // Rounded up, so a reset seconds away reads "in 1m", never "in 0m" or a negative time.
            let total = max(Int((seconds / 60).rounded(.up)), 1)
            let hours = total / 60, minutes = total % 60
            return hours > 0 ? "in \(hours)h \(minutes)m" : "in \(minutes)m"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour())
    }
}

enum TokenCount {
    static func short(_ value: Int) -> String {
        let number = Double(value)
        switch number {
        case 1e9...: return String(format: "%.1fB", number / 1e9)
        case 1e6...: return String(format: "%.1fM", number / 1e6)
        case 1e3...: return String(format: "%.0fK", number / 1e3)
        default: return "\(value)"
        }
    }
    static func clock(_ minutes: Int) -> String {
        let value = (minutes % 1440 + 1440) % 1440
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

struct TourAnchorIf: ViewModifier {
    let step: TourStep
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.tourAnchor(step) } else { content }
    }
}
