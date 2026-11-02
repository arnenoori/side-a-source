import SafariServices
import SideAProtocol
import SwiftUI

/// Autopilot under the accounts (section 4.14): on or off, a move it's holding with Move Now, then its
/// decisions, newest first, each opening to the sessions it moved. A section for a `List`.
struct AutopilotLiveSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var moving = false
    @State private var error: String?
    @State private var moved = 0
    @State private var failed = 0
    @State private var toggling = false

    private var state: AutopilotState? { model.tools.autopilot }

    /// The holds, then what happened; a hold's wait in the log is that same hold.
    private func rows(_ state: AutopilotState) -> [AutopilotDecision] {
        let held = state.held ?? []
        return held + state.decisions.filter { row in !(row.kind == .waiting && held.contains { $0.from == row.from && $0.to == row.to }) }
    }

    private var canToggle: Bool { model.tools.can(.autopilotToggle) }

    var body: some View {
        if model.tools.can(.autopilot) || model.isDemo {
            Section {
                if let state {
                    if canToggle {
                        Toggle("Autopilot", isOn: Binding(get: { state.enabled }, set: { toggle($0) }))
                            .disabled(toggling)
                    }
                    if model.tools.can(.autopilotAnswers), let answers = state.answersRecommended {
                        Toggle("Answer with recommended after 1 minute", isOn: Binding(get: { answers }, set: { toggleAnswers($0) }))
                            .disabled(toggling)
                    }
                    if model.tools.can(.rotation) {
                        if let swapAt = state.swapAt {
                            Picker("Move at", selection: Binding(get: { swapAt }, set: { percent in change { try await model.tools.setSwapAt(percent) } })) {
                                ForEach(SwapAtChange.choices, id: \.self) { Text("\($0)%").tag($0) }
                            }
                            .disabled(toggling)
                        }
                        if let follow = state.followFable {
                            Toggle("Follow Fable", isOn: Binding(get: { follow }, set: { enabled in change { try await model.tools.setFollowFable(enabled) } }))
                                .disabled(toggling)
                        }
                    }
                    if rows(state).isEmpty {
                        Text(state.enabled ? "No moves yet." : canToggle ? "Off." : "Off. Change it on \(model.mac.name).")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows(state)) { AutopilotDecisionRow(decision: $0) }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Autopilot")
                    if let state, !canToggle { Text(state.enabled ? "On" : "Off").foregroundStyle(.secondary) }
                    Spacer()
                    if let pending = state?.pending {
                        if moving {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Move Now") { confirming = true }
                                .font(.footnote.weight(.semibold))
                                .textCase(nil)
                                .confirmationDialog(pending.title, isPresented: $confirming, titleVisibility: .visible) {
                                    Button("Move Now") { moveNow() }
                                } message: {
                                    Text(Self.moveMessage(pending))
                                }
                        }
                    }
                }
            } footer: {
                if let error, state != nil { Text(error) }
            }
            .sensoryFeedback(.success, trigger: moved)
            .sensoryFeedback(.error, trigger: failed)
            .task { await load() }
        }
    }

    static func moveMessage(_ pending: AutopilotDecision) -> String {
        let titles = pending.sessions.map(\.title).formatted(.list(type: .and))
        let route = [pending.from, pending.to].compactMap { $0 }.joined(separator: " → ")
        let cost = pending.recacheTokens.map { "They lose their prompt cache, about \($0.formatted(.number.notation(.compactName))) tokens to write again." }
        return [titles.isEmpty ? nil : "\(titles) move\(route.isEmpty ? "" : " \(route)").", cost ?? "They lose their prompt cache."]
            .compactMap { $0 }.joined(separator: " ")
    }

    private func load() async {
        guard !model.isDemo else { return }
        do { try await model.tools.loadAutopilot(); error = nil } catch { self.error = MacTools.message(error) }
    }

    /// After Face ID either way; a cancel leaves the switch where it was.
    private func toggle(_ enabled: Bool) { change { try await model.tools.setAutopilot(enabled) } }

    private func toggleAnswers(_ enabled: Bool) { change { try await model.tools.setAnswersRecommended(enabled) } }

    private func change(_ call: @escaping () async throws -> Void) {
        toggling = true
        Task {
            defer { toggling = false }
            do {
                try await call()
                error = nil
                moved += 1
            } catch ToolError.cancelled {
            } catch {
                self.error = MacTools.message(error)
                failed += 1
            }
        }
    }

    private func moveNow() {
        guard !model.isDemo else { error = MacTools.message(ToolError.demo); return }
        moving = true
        Task {
            defer { moving = false }
            do {
                try await model.tools.moveNow()
                error = nil
                moved += 1
            } catch {
                self.error = MacTools.message(error)
                failed += 1
            }
        }
    }
}

private struct AutopilotDecisionRow: View {
    let decision: AutopilotDecision
    @Environment(AppModel.self) private var model

    var body: some View {
        if decision.sessions.isEmpty {
            label
        } else {
            DisclosureGroup {
                ForEach(decision.sessions, id: \.sessionID) { moved in
                    NavigationLink(value: Route.session(moved.sessionID, mac: model.macID)) { Text(moved.title).font(.subheadline) }
                }
            } label: { label }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Label { headline } icon: {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                Spacer()
                Text(Date(timeIntervalSince1970: decision.at).formatted(date: .omitted, time: .shortened))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !inline, !decision.reason.isEmpty {
                Text(decision.reason).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// A move's reason is a few words, so it reads on the same line: "Work → Personal · 5-hour 96%".
    private var inline: Bool { decision.kind == .moved && decision.reason.count <= 32 }

    private var headline: Text {
        guard inline, !decision.reason.isEmpty else { return Text(decision.title).font(.subheadline.weight(.medium)) }
        // Non-breaking, so a wrap moves the whole reason down instead of splitting "5-hour".
        let reason = decision.reason.replacingOccurrences(of: " ", with: "\u{00A0}").replacingOccurrences(of: "-", with: "\u{2011}")
        return Text(decision.title).font(.subheadline.weight(.medium))
            + Text(" · \(reason)").font(.subheadline).foregroundStyle(.secondary)
    }

    private var symbol: String {
        switch decision.kind {
        case .moved: "arrow.left.arrow.right"
        case .waiting: "hourglass"
        case .failed: "exclamationmark.triangle"
        case .answered: "checkmark.bubble"
        case .stuck: "pause.circle"
        case .priorityWait: "clock"
        default: "sparkles"
        }
    }

    private var tint: Color {
        switch decision.kind {
        case .failed, .stuck: .orange
        case .waiting, .priorityWait: .secondary
        default: .accentColor
        }
    }
}

/// While a provider's status page reports an incident: a row at the top of Sessions and Accounts that
/// opens the status page. A row for a `List`.
struct IncidentBanner: View {
    @Environment(AppModel.self) private var model
    @State private var opened: Incident?

    var body: some View {
        let open = model.tools.incidents.filter { $0.status != .resolved }
        if model.tools.can(.incidents), !open.isEmpty {
            Section {
                ForEach(open) { incident in
                    Button {
                        opened = incident
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(incident.provider == .claude ? "Claude" : "Codex") incident: \(incident.title)")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(incident.status.rawValue.capitalized).font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                        }
                    }
                    .disabled(URL(string: incident.url) == nil)
                }
            }
            .sheet(item: $opened) { incident in
                if let url = URL(string: incident.url) { SafariView(url: url).ignoresSafeArea() }
            }
        }
    }
}

/// A provider's status page, in Safari's own view.
private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
