import SideAProtocol
import SideARemoteShared
import SwiftUI

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
            ToolbarItem(placement: .topBarTrailing) { SheetButton(sheet: .settings) }
        }
        .refreshable {
            let failed = await withTaskGroup(of: Bool.self) { group in
                for mac in macs {
                    group.addTask {
                        do { try await mac.link?.engine.refreshAccounts() } catch { return true }
                        return false
                    }
                    group.addTask {
                        await mac.tools.loadOutlook()
                        return false
                    }
                }
                var failed = false
                for await result in group where result { failed = true }
                return failed
            }
            if failed { Pill.show("Couldn't refresh accounts") }
        }
        .overlay {
            if macs.allSatisfy({ $0.accounts.accounts.isEmpty }) {
                switch Self.emptyState(macs.map(\.mac.state)) {
                case .noAccounts: ContentUnavailableView("No Accounts", systemImage: "person.crop.circle")
                case .pairAgain(let reason):
                    PairAgainView(reason: reason, mac: root.current.mac.name).background(Color(.systemGroupedBackground))
                case .waiting: ProgressView()
                case .banner: EmptyView()
                }
            }
        }
    }

    enum Empty: Equatable {
        case noAccounts, waiting, banner
        case pairAgain(MacConnection.Offline)
    }

    static func emptyState(_ states: [MacConnection.State]) -> Empty {
        if states.allSatisfy({ $0 == .live }) { return .noAccounts }
        if states.count == 1, case .offline(let reason) = states[0], reason.needsPairing { return .pairAgain(reason) }
        if states.contains(where: \.isOffline) { return .banner }
        return .waiting
    }
}

private struct MacAccounts: View {
    let now: Date
    let header: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let accounts = model.accounts.accounts
        let fableMode = model.tools.autopilot?.fableMode == true
        let attention = accounts.filter { $0.issue != nil && $0.issue?.kind != .offline }
        let providers = AgentProvider.allCases.map { provider in
            (provider, accounts.filter { $0.provider == provider && !attention.contains($0) })
        }.filter { !$0.1.isEmpty }
        if header {
            Section {} header: {
                HStack(spacing: 6) {
                    ConnectionDot(state: model.mac.shown)
                    Text(model.mac.name)
                }
                .foregroundStyle(.primary)
            }
            .headerProminence(.increased)
        }
        IncidentBanner()
        ConnectionBanners()
        RotationSummarySection(now: now)
        if !attention.isEmpty {
            Section("Needs Attention") { rows(attention) }
        }
        ForEach(providers, id: \.0) { provider, accounts in
            let limited = accounts.filter { !$0.active && ($0.limited(at: now) || (fableMode && $0.fableOut(at: now))) }
            let rest = accounts.filter { !$0.active && !limited.contains($0) }.sorted { $0.used(at: now) < $1.used(at: now) }
            Section {
                if let active = accounts.first(where: \.active) {
                    link(active) { ActiveAccountCard(account: active, now: now, fableMode: fableMode) }
                }
                rows(rest)
                if !limited.isEmpty {
                    DisclosureGroup {
                        rows(limited)
                    } label: {
                        Text(Self.limitedLine(limited, now: now)).foregroundStyle(.secondary)
                    }
                }
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
            link(account) { AccountRow(account: account, now: now, fableMode: model.tools.autopilot?.fableMode == true) }
                .swipeActions(edge: .leading, allowsFullSwipe: true) { if usable(account) { useButton(account).tint(.accentColor) } }
                .contextMenu { if usable(account) { useButton(account) } }
        }
    }

    private func usable(_ account: RemoteAccount) -> Bool { model.tools.can(.accountsUse) && !account.active && account.ready }

    private func useButton(_ account: RemoteAccount) -> some View {
        Button("Use", systemImage: "arrow.left.arrow.right") { use(account) }.needsMac()
    }

    private func use(_ account: RemoteAccount) {
        let model = model
        Task {
            do {
                try await model.use(account)
            } catch ToolError.cancelled {} catch {
                Pill.show(MacTools.message(error))
            }
        }
    }

    private func link(_ account: RemoteAccount, @ViewBuilder label: () -> some View) -> some View {
        NavigationLink(value: Route.account(account.id, mac: model.macID), label: label)
            .zoomSource("account-\(model.macID)-\(account.id)")
    }

    static func limitedLine(_ limited: [RemoteAccount], now: Date) -> String {
        let back = limited.compactMap { $0.backAt ?? $0.binding(at: now)?.resetsAt }.filter { $0 > now.timeIntervalSince1970 }.min()
        return "\(limited.count) limited" + (back.map { " · next back \(Formatting.at(Date(timeIntervalSince1970: $0), now: now))" } ?? "")
    }
}

extension UsageWindow {
    var shortLabel: String {
        switch id {
        case "five_hour": "5h"
        case "seven_day": "wk"
        default: label.replacingOccurrences(of: "Weekly ", with: "")
        }
    }

    var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }

    static func tint(used: Double) -> Color {
        switch used {
        case 90...: .red
        case 75...: .orange
        default: .green
        }
    }
}

extension RemoteAccount {
    static let limitedAt = 97.0

    func binding(at now: Date) -> UsageWindow? {
        let windows = limited == nil ? usage?.windows : usage?.windows.filter { !$0.id.hasPrefix("model:") }
        return windows?.max { $0.used(at: now.timeIntervalSince1970) < $1.used(at: now.timeIntervalSince1970) }
    }

    func used(at now: Date) -> Double { binding(at: now)?.used(at: now.timeIntervalSince1970) ?? 0 }
    func limited(at now: Date) -> Bool {
        guard let limited else { return used(at: now) >= Self.limitedAt }
        return limited && (backAt ?? .infinity) > now.timeIntervalSince1970
    }

    func fableOut(at now: Date) -> Bool { fableOut == true && (backAt ?? .infinity) > now.timeIntervalSince1970 }

    func needsAttention(at now: Date, fableMode: Bool = false) -> Bool {
        used(at: now) >= 90 || limited(at: now) || (fableMode && fableOut(at: now)) || (issue != nil && issue?.kind != .offline)
    }

    func staleSince(now: Date = .now) -> Date? {
        guard let readAt else { return nil }
        let date = Date(timeIntervalSince1970: readAt)
        return (usage?.stale == true || now.timeIntervalSince(date) > 15 * 60) ? date : nil
    }
}

extension Formatting {
    static func until(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds < 86_400 else { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return minutes < 60 ? "in \(minutes)m" : "in \(minutes / 60)h \(minutes % 60)m"
    }

    static func at(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func ago(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : date.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
    }
}

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
            if let window = account.headline(at: now) {
                let used = window.used(at: now.timeIntervalSince1970)
                UsageBar(used: used).frame(width: 64)
                Text(Formatting.percent(used))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .trailing)
                    .contentTransition(.numericText(value: used))
            }
        }
        .opacity(account.staleSince(now: now) == nil ? 1 : 0.6)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    var subtitle: (text: String, alarm: Bool)? {
        if let issue = account.issue.flatMap({ RotationText.issue($0, now: now) }) { return issue }
        if account.limited(at: now) {
            let back = account.backAt.map(Date.init(timeIntervalSince1970:)) ?? account.binding(at: now)?.resetDate
            return ("Limited" + (back.map { " · back \(Formatting.at($0, now: now))" } ?? ""), true)
        }
        if account.fableOut(at: now) {
            return ("Fable out" + (account.backAt.map { " · back \(Formatting.at(Date(timeIntervalSince1970: $0), now: now))" } ?? ""), fableMode)
        }
        if let reset = account.headline(at: now)?.resetDate, reset > now { return ("Resets \(Formatting.until(reset, now: now))", false) }
        if let stale = account.staleSince(now: now) { return ("As of \(Formatting.at(stale, now: now))", false) }
        if account.active { return ("In use", false) }
        return nil
    }

    private var accessibilityText: String {
        var parts = [account.name]
        if let plan = RotationText.plan(account) { parts.append("\(plan) plan") }
        if let subtitle { parts.append(subtitle.text) }
        if account.active, subtitle?.text != "In use" { parts.append("In use") }
        if let window = account.headline(at: now) {
            parts.append("\(Int(window.used(at: now.timeIntervalSince1970).rounded())) percent of \(window.id == "seven_day" ? "the week" : window.label) used")
        }
        return parts.joined(separator: ", ")
    }
}

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
            .refreshable {
                do { try await model.link?.engine.refreshAccounts() } catch { Pill.show("Couldn't refresh accounts") }
            }
            .sessionActions()
            .zoomDestination("account-\(model.macID)-\(account.id)")
        }
    }
}

extension AccountDetailView {
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
                try await model.use(account)
                switched += 1
            } catch ToolError.cancelled {
            } catch {
                failure = MacTools.message(error)
            }
        }
    }
}

extension AppModel {
    /// Asks for Face ID; the demo has no host to ask and switches its sample accounts itself.
    func use(_ account: RemoteAccount) async throws {
        guard isDemo else { return try await tools.useAccount(account) }
        accounts.replace(accounts.accounts.map { $0.provider == account.provider ? $0.with(active: $0.id == account.id) : $0 })
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

private struct WindowBlock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let window: UsageWindow
    let now: Date
    var accountLimited = true

    var body: some View {
        let used = window.used(at: now.timeIntervalSince1970)
        let limited = used >= RemoteAccount.limitedAt && (accountLimited || window.id.hasPrefix("model:"))
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(.headline)
            UsageBar(used: used)
            HStack {
                Text(limited ? "Limited" : "\(Formatting.percent(used)) used")
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
