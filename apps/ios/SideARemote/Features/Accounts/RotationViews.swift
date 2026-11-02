import SideAProtocol
import SideARemoteShared
import SwiftUI

/// The words rotation shows, apart from the views so each can be tested.
enum RotationText {
    /// "Work back 4:10 PM", or "back by" when the Mac only knows the longest it could take.
    static func back(_ account: String, at: Timestamp, worstCase: Bool = false, now: Date) -> String {
        "\(account) back \(worstCase ? "by " : "")\(Formatting.at(Date(timeIntervalSince1970: at), now: now))"
    }

    /// "3 waiting · Work back 4:10 PM".
    static func waiting(count: Int, summary: WaitingSummary?, now: Date) -> String {
        let back = summary.flatMap { $0.at > now.timeIntervalSince1970 ? Self.back($0.account, at: $0.at, worstCase: $0.worstCase, now: now) : nil }
        return ["\(count) waiting", back].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Next: Personal · at 95% · ~40m". With several logins in use, each says which it is.
    static func next(_ move: NextMove, several: Bool) -> String {
        let lead = several ? "\(move.from) → \(move.to ?? "none free")" : "Next: \(move.to ?? "none free")"
        guard move.to != nil else { return lead }
        if move.held { return "\(lead) · after a pause" }
        return ([lead, "at \(move.atPercent)%"] + [move.minutes.map(estimate)].compactMap { $0 }).joined(separator: " · ")
    }

    /// "~40m", "~1h 20m": the Mac's reading of the pace, never a promise.
    static func estimate(_ minutes: Int) -> String {
        minutes < 60 ? "~\(minutes)m" : minutes % 60 == 0 ? "~\(minutes / 60)h" : "~\(minutes / 60)h \(minutes % 60)m"
    }

    /// "41% left · runs out Thu". The date only when the Mac could work one out.
    static func room(_ room: UsageOutlook.Room, named: Bool, now: Date) -> String {
        let left = "\(named ? "\(room.provider.title) " : "")\(room.weeklyLeft)% left"
        guard let runsOut = room.runsOut, runsOut > now.timeIntervalSince1970 else { return left }
        let date = Date(timeIntervalSince1970: runsOut)
        let day = Calendar.current.isDate(date, inSameDayAs: now) ? "today" : date.formatted(.dateTime.weekday(.abbreviated))
        return "\(left) · runs out \(day)"
    }

    /// "5x" for a plan bigger than Pro; Codex reports no plan size.
    static func plan(_ account: RemoteAccount) -> String? {
        guard account.provider == .claude, let capacity = account.usage?.capacity, capacity > 1, capacity.rounded() == capacity else { return nil }
        return "\(Int(capacity))x"
    }

    /// What's keeping Autopilot off an account, and whether it already is.
    static func issue(_ issue: AccountIssue, now: Date) -> (text: String, alarm: Bool)? {
        switch issue.kind {
        case .signedOut: return ("Signed out", true)
        case .signIn: return ("Sign in again", true)
        case .replaced: return (issue.replacedBy.map { "Login replaced by \($0)" } ?? "Sign in again", true)
        case .verifying: return ("Checking whose login this is", false)
        case .offline: return ("Couldn't read its limits", false)
        case .signInEnds:
            guard let ends = issue.endsAt else { return nil }
            let date = Date(timeIntervalSince1970: ends)
            if date <= now { return ("Sign-in ended", true) }
            let today = Calendar.current.isDate(date, inSameDayAs: now)
            return ("Sign-in ends \(today ? "today" : date.formatted(.dateTime.weekday(.abbreviated)))", false)
        default: return nil
        }
    }

    static func priority(_ level: PriorityLevel) -> String {
        switch level {
        case .first: "First"
        case .last: "Last"
        default: "Normal"
        }
    }
}

extension RemoteSession {
    /// Stopped on a limit that hasn't reset yet.
    func waitingOnLimit(at now: Date) -> Bool {
        guard let limit else { return false }
        return (limit.until ?? .infinity) > now.timeIntervalSince1970
    }
}

/// The top of Accounts: who's waiting, what's left altogether, and where sessions go next. A section for a `List`.
struct RotationSummarySection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let now: Date

    var body: some View {
        let waiting = model.sessions.sessions.filter { $0.waitingOnLimit(at: now) }
        let rooms = (model.tools.outlook?.rooms ?? []).filter { $0.accounts > 1 }
        let next = model.tools.autopilot?.next ?? []
        if !waiting.isEmpty || !rooms.isEmpty || !next.isEmpty {
            Section {
                if !waiting.isEmpty {
                    NavigationLink(value: Route.waiting(mac: model.macID)) {
                        row(RotationText.waiting(count: waiting.count, summary: model.tools.autopilot?.waiting, now: now), symbol: "hourglass", tint: .amber)
                    }
                }
                ForEach(rooms) { room in
                    row(RotationText.room(room, named: rooms.count > 1, now: now), symbol: "chart.pie.fill", tint: .secondary)
                }
                ForEach(next) { move in
                    row(RotationText.next(move, several: next.count > 1), symbol: "arrow.left.arrow.right", tint: .secondary)
                }
            }
        }
    }

    private func row(_ text: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(text)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .accessibilityLabel(text.replacingOccurrences(of: " · ", with: ", ").replacingOccurrences(of: "~", with: "about "))
    }
}

/// The sessions stopped on a limit, from the row at the top of Accounts.
struct WaitingSessionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let waiting = model.sessions.sessions.filter { $0.waitingOnLimit(at: context.date) }
            List(waiting) { session in
                NavigationLink(value: Route.session(session.id, mac: model.macID)) { SessionRow(session: session) }
            }
            .overlay {
                if waiting.isEmpty { ContentUnavailableView("No Sessions Waiting", systemImage: "checkmark.circle") }
            }
        }
        .navigationTitle("Waiting")
        .sessionActions()
    }
}

/// An account's plan size, as a small badge beside its name.
struct PlanBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
            .accessibilityLabel("\(text) plan")
    }
}

/// First, Normal or Last, and whether Autopilot may use it. Each change waits on Face ID, so a cancel leaves it as it was.
struct RotationControls: View {
    @Environment(AppModel.self) private var model
    let account: RemoteAccount
    @State private var changing = false
    @State private var failure: String?
    @State private var changed = 0

    var body: some View {
        if model.tools.can(.rotation), let priority = account.priority, let auto = account.allowAuto {
            Section("Rotation") {
                Toggle("Autopilot", isOn: Binding(get: { auto }, set: { enabled in
                    change {
                        if model.isDemo { demo { $0.copy(allowAuto: enabled) } } else { try await model.tools.setAuto(account, enabled) }
                    }
                }))
                    .tint(.green)
                Picker("Priority", selection: Binding(get: { priority }, set: { level in
                    change {
                        if model.isDemo { demo { $0.copy(priority: level) } } else { try await model.tools.setPriority(account, level) }
                    }
                })) {
                    ForEach(PriorityLevel.all, id: \.self) { Text(RotationText.priority($0)).tag($0) }
                }
            }
            .disabled(changing)
            .sensoryFeedback(.success, trigger: changed)
            .alert("Couldn't Change", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
    }

    private func demo(_ edit: (RemoteAccount) -> RemoteAccount) {
        model.accounts.replace(model.accounts.accounts.map { $0.id == account.id ? edit($0) : $0 })
    }

    private func change(_ call: @escaping () async throws -> Void) {
        changing = true
        Task {
            defer { changing = false }
            do {
                try await call()
                changed += 1
            } catch ToolError.cancelled {
            } catch {
                failure = MacTools.message(error)
            }
        }
    }
}
