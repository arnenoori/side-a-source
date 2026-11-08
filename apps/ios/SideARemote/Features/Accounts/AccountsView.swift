import SideAProtocol
import SideARemoteShared
import SwiftUI

/// Accounts: what's left on each account. Accounts at 90% or limited come first, soonest
/// reset on top; then each provider, most left first. The clock moves once a minute, never in seconds.
struct AccountsView: View {
    @Environment(AppRoot.self) private var root

    var body: some View {
        let macs = root.visible
        TimelineView(.periodic(from: .now, by: 60)) { context in
            List {
                if macs.count > 1 {
                    ForEach(macs, id: \.macID) { mac in
                        MacAccounts(now: context.date, header: true).environment(mac)
                    }
                } else {
                    MacAccounts(now: context.date, header: false).environment(root.current)
                }
            }
            .listStyle(.insetGrouped)
        }
        .task(id: macs.map { $0.accounts.updated }) {
            for mac in macs { await mac.tools.loadOutlook() }
        }
        .navigationTitle("Accounts")
        .toolbar {
            if root.macs.count > 1 {
                ToolbarItem(placement: .topBarLeading) { MacsMenu() }
            }
        }
        .refreshable {
            await withTaskGroup { group in
                for mac in macs {
                    group.addTask { try? await mac.link?.engine.refreshAccounts() }
                    group.addTask { await mac.tools.loadOutlook() }
                }
            }
        }
        .overlay {
            if macs.allSatisfy({ $0.accounts.accounts.isEmpty }) {
                ContentUnavailableView("No Accounts", systemImage: "person.crop.circle")
            }
        }
    }
}

/// One Mac's accounts. With several Macs, each Mac's are under its name, since each signs in on its own.
private struct MacAccounts: View {
    let now: Date
    let header: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let accounts = model.accounts.accounts
        let fableMode = model.tools.autopilot?.fableMode == true
        let attention = accounts.filter { $0.needsAttention(at: now, fableMode: fableMode) }
            .sorted { ($0.binding(at: now)?.resetsAt ?? .infinity) < ($1.binding(at: now)?.resetsAt ?? .infinity) }
        let providers = AgentProvider.allCases.map { provider in
            (provider, accounts.filter { $0.provider == provider && !$0.needsAttention(at: now, fableMode: fableMode) }
                .sorted { $0.left(at: now) > $1.left(at: now) })
        }.filter { !$0.1.isEmpty }
        if header {
            Section {} header: {
                HStack(spacing: 6) {
                    ConnectionDot(state: model.mac.state)
                    Text(model.mac.name)
                }
                .foregroundStyle(.primary)
            }
            .headerProminence(.increased)
        }
        IncidentBanner()
        RotationSummarySection(now: now)
        if !attention.isEmpty {
            Section("Needs Attention") { rows(attention) }
        }
        ForEach(providers, id: \.0) { provider, accounts in
            Section {
                rows(accounts)
            } header: {
                Text(provider.title)
            } footer: {
                if provider == providers.last?.0, let updated = model.accounts.updated {
                    Text("Updated \(Formatting.ago(updated, now: now))")
                }
            }
        }
        AutopilotLiveSection()
    }

    private func rows(_ accounts: [RemoteAccount]) -> some View {
        ForEach(accounts) { account in
            NavigationLink(value: Route.account(account.id, mac: model.macID)) {
                AccountRow(account: account, now: now, fableMode: model.tools.autopilot?.fableMode == true)
            }
            .zoomSource("account-\(model.macID)-\(account.id)")
        }
    }
}

extension UsageWindow {
    /// "5h", "wk", or the model's name for a model cap.
    var shortLabel: String {
        switch id {
        case "five_hour": "5h"
        case "seven_day": "wk"
        default: label.replacingOccurrences(of: "Weekly ", with: "")
        }
    }

    /// Fraction left, 0...1, counting a window that has reset as full.
    func left(at now: Date) -> Double { 1 - used(at: now.timeIntervalSince1970) / 100 }

    var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }

    /// Green while there's room, orange from 75% used, red from 90%. Words always say the same.
    static func tint(used: Double) -> Color {
        switch used {
        case 90...: .red
        case 75...: .orange
        default: .green
        }
    }
}

extension RemoteAccount {
    /// Side A calls an account limited from 97%.
    static let limitedAt = 97.0

    /// The window closest to its limit. A Mac that serves `limited` has judged the account's own limits itself, so a cap
    /// on one model alone doesn't stand for the account here.
    func binding(at now: Date) -> UsageWindow? {
        let windows = limited == nil ? usage?.windows : usage?.windows.filter { !$0.id.hasPrefix("model:") }
        return windows?.max { $0.used(at: now.timeIntervalSince1970) < $1.used(at: now.timeIntervalSince1970) }
    }

    func used(at now: Date) -> Double { binding(at: now)?.used(at: now.timeIntervalSince1970) ?? 0 }
    func left(at now: Date) -> Double { 1 - used(at: now) / 100 }
    /// The Mac's word when it gave one, until the moment it said that ends.
    func limited(at now: Date) -> Bool {
        guard let limited else { return used(at: now) >= Self.limitedAt }
        return limited && (backAt ?? .infinity) > now.timeIntervalSince1970
    }

    func fableOut(at now: Date) -> Bool { fableOut == true && (backAt ?? .infinity) > now.timeIntervalSince1970 }

    func needsAttention(at now: Date, fableMode: Bool = false) -> Bool {
        used(at: now) >= 90 || limited(at: now) || (fableMode && fableOut(at: now)) || (issue != nil && issue?.kind != .offline)
    }

    /// A reading older than 15 minutes says how old it is.
    func staleSince(now: Date = .now) -> Date? {
        guard let readAt else { return nil }
        let date = Date(timeIntervalSince1970: readAt)
        return (usage?.stale == true || now.timeIntervalSince(date) > 15 * 60) ? date : nil
    }
}

extension Formatting {
    /// "in 1h 12m" under a day, "Tue 9:00 AM" beyond.
    static func until(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds < 86_400 else { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return minutes < 60 ? "in \(minutes)m" : "in \(minutes / 60)h \(minutes % 60)m"
    }

    /// "3:40 PM" today, "Tue 9:00 AM" beyond.
    static func at(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// "just now", "2 min ago", "1 hr ago".
    static func ago(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : date.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
    }
}

/// Monogram, name, one line about the tightest limit, and two small gauges of what's left.
struct AccountRow: View {
    let account: RemoteAccount
    let now: Date
    var fableMode = false

    var body: some View {
        HStack(spacing: Space.s) {
            Monogram(name: account.name, seed: account.id)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xxs) {
                    Text(account.name).lineLimit(1).truncationMode(.middle)
                    if let plan = RotationText.plan(account) { PlanBadge(text: plan) }
                    if account.active {
                        Image(systemName: "checkmark.circle.fill").font(.footnote).foregroundStyle(.tint)
                    }
                }
                if let subtitle {
                    Text(subtitle.text)
                        .font(.subheadline)
                        .foregroundStyle(subtitle.alarm ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .contentTransition(.numericText())
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Space.xs)
            HStack(spacing: Space.xs) {
                ForEach([account.usage?.fiveHour, account.usage?.weekly].compactMap { $0 }, id: \.id) { window in
                    LeftGauge(window: window, now: now)
                }
            }
            .opacity(account.staleSince(now: now) == nil ? 1 : 0.5)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var subtitle: (text: String, alarm: Bool)? {
        if let issue = account.issue.flatMap({ RotationText.issue($0, now: now) }) { return issue }
        if account.limited(at: now) {
            let back = account.backAt.map(Date.init(timeIntervalSince1970:)) ?? account.binding(at: now)?.resetDate
            return ("Limited" + (back.map { " · back \(Formatting.at($0, now: now))" } ?? ""), true)
        }
        if account.fableOut(at: now) {
            return ("Fable out" + (account.backAt.map { " · back \(Formatting.at(Date(timeIntervalSince1970: $0), now: now))" } ?? ""), fableMode)
        }
        if let window = account.binding(at: now), window.used(at: now.timeIntervalSince1970) >= 50, let reset = window.resetDate {
            return ("Resets \(Formatting.until(reset, now: now))", false)
        }
        if let stale = account.staleSince(now: now) { return ("As of \(Formatting.at(stale, now: now))", false) }
        if account.active { return ("In use", false) }
        return nil
    }

    private var accessibilityText: String {
        var parts = [account.name]
        if let plan = RotationText.plan(account) { parts.append("\(plan) plan") }
        if let subtitle { parts.append(subtitle.text) }
        if account.active, subtitle?.text != "In use" { parts.append("In use") }
        for window in [account.usage?.fiveHour, account.usage?.weekly].compactMap({ $0 }) {
            parts.append("\(window.id == "five_hour" ? "5-hour" : "Weekly") \(Int((window.left(at: now) * 100).rounded())) percent left")
        }
        return parts.joined(separator: ", ")
    }
}

/// A 28 pt circle with the account's initial, its colour fixed by its id.
private struct Monogram: View {
    let name: String
    let seed: String

    private static let palette: [Color] = [.blue, .indigo, .purple, .pink, .teal, .cyan, .mint, .brown]

    var body: some View {
        let hue = Self.palette[abs(seed.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % Self.palette.count]
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(hue.gradient, in: .circle)
            .accessibilityHidden(true)
    }
}

/// What's left of one window, as a small capacity ring with "5h" or "wk" inside.
private struct LeftGauge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let window: UsageWindow
    let now: Date

    var body: some View {
        Gauge(value: window.left(at: now)) {
            Text(window.shortLabel)
        } currentValueLabel: {
            Text(window.shortLabel)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(UsageWindow.tint(used: window.used(at: now.timeIntervalSince1970)))
        .scaleEffect(0.6)
        .frame(width: 34, height: 34)
        .animation(Motion.smooth(reduceMotion), value: window.percent)
    }
}

/// Autopilot's recent moves, read-only on the phone.
/// One account: a block per window with what's left and when it resets, then its sessions.
struct AccountDetailView: View {
    @Environment(AppModel.self) private var model
    let accountID: String
    @State private var switching = false
    @State private var failure: String?
    @State private var switched = 0

    var body: some View {
        if let account = model.accounts.accounts.first(where: { $0.id == accountID }) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                List {
                    if let issue = account.issue.flatMap({ RotationText.issue($0, now: context.date) }) {
                        Section {
                            Label {
                                Text(issue.text).foregroundStyle(issue.alarm ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                            } icon: {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(issue.alarm ? .red : .orange)
                            }
                        } footer: {
                            if [.signedOut, .signIn, .replaced, .signInEnds].contains(account.issue?.kind) {
                                Text("Sign in on \(model.mac.name).")
                            }
                        }
                    }
                    Section {
                        ForEach(account.usage?.windows ?? [], id: \.id) { WindowBlock(window: $0, now: context.date, accountLimited: account.limited == nil || account.limited(at: context.date)) }
                    }
                    if let extra = account.usage?.extra, extra.enabled {
                        Section { LabeledContent("Extra usage", value: extra.summary) }
                    }
                    useSection(account)
                    RotationControls(account: account)
                    let sessions = model.sessions.sessions.filter { $0.accountName == account.name }
                    if !sessions.isEmpty {
                        Section("Sessions") {
                            ForEach(sessions) { session in
                                NavigationLink(value: Route.session(session.id, mac: model.macID)) { SessionRow(session: session) }
                            }
                        }
                    }
                    if let stale = account.staleSince(now: context.date) {
                        Section {} footer: { Text("Updated \(Formatting.ago(stale, now: context.date))") }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .sensoryFeedback(.success, trigger: switched)
            .alert("Couldn't Switch", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
            .navigationTitle(account.name)
            .navigationSubtitle(account.email)
            .refreshable { try? await model.link?.engine.refreshAccounts() }
            // Its session rows' swipes and menus.
            .sessionActions()
            .zoomDestination("account-\(model.macID)-\(account.id)")
        }
    }
}

extension AccountDetailView {
    /// Use This Account, where the Mac takes it: the account becomes its provider's login on the Mac, after Face ID.
    @ViewBuilder private func useSection(_ account: RemoteAccount) -> some View {
        if model.tools.can(.accountsUse) {
            Section {
                if account.active {
                    Label {
                        Text("In Use").foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                    }
                } else {
                    Button {
                        use(account)
                    } label: {
                        HStack {
                            Text("Use This Account")
                            Spacer()
                            if switching { ProgressView() }
                        }
                    }
                    .disabled(switching || !account.ready)
                }
            } footer: {
                if !account.ready {
                    Text("Sign in to \(account.name) on \(model.mac.name) first.")
                }
            }
        }
    }

    private func use(_ account: RemoteAccount) {
        switching = true
        Task {
            defer { switching = false }
            do {
                if model.isDemo {
                    model.accounts.replace(model.accounts.accounts.map { $0.provider == account.provider ? $0.with(active: $0.id == account.id) : $0 })
                } else {
                    try await model.tools.useAccount(account)
                }
                switched += 1
            } catch ToolError.cancelled {
            } catch {
                failure = MacTools.message(error)
            }
        }
    }
}

extension RemoteAccount {
    func with(active: Bool) -> RemoteAccount {
        copy(active: active)
    }

    func copy(active: Bool? = nil, priority: PriorityLevel? = nil, allowAuto: Bool? = nil) -> RemoteAccount {
        RemoteAccount(id: id, name: name, email: email, provider: provider, ready: ready, active: active ?? self.active, usage: usage, readAt: readAt,
                      sessions: sessions, priority: priority ?? self.priority, allowAuto: allowAuto ?? self.allowAuto, limited: limited,
                      fableOut: fableOut, backAt: backAt, issue: issue)
    }
}

/// "5-hour window", a bar of what's left, then "62% left" and "Resets 3:40 PM".
private struct WindowBlock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let window: UsageWindow
    let now: Date
    /// A window at 97% says Limited only if the Mac agrees the account is; a cap on one model is its own limit.
    var accountLimited = true

    var body: some View {
        let used = window.used(at: now.timeIntervalSince1970)
        let limited = used >= RemoteAccount.limitedAt && (accountLimited || window.id.hasPrefix("model:"))
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(.headline)
            ProgressView(value: window.left(at: now))
                .tint(UsageWindow.tint(used: used))
            HStack {
                Text(limited ? "Limited" : "\(Int((window.left(at: now) * 100).rounded()))% left")
                    .foregroundStyle(limited ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    .contentTransition(.numericText())
                Spacer()
                if let reset = window.resetDate, reset > now {
                    Text("Resets \(Formatting.at(reset, now: now))").foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.monospacedDigit())
        }
        .padding(.vertical, Space.xxs)
        .animation(Motion.smooth(reduceMotion), value: window.percent)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch window.id {
        case "five_hour": "5-hour window"
        case "seven_day": "Weekly"
        default: window.label
        }
    }
}
