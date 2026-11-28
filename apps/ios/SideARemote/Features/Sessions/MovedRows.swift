import SideAProtocol
import SwiftUI

/// Sessions this host sent to another computer, is sending, or lost track of on the way, dimmed under its own.
struct MovedSection: View {
    let query: String
    @Environment(AppModel.self) private var model

    static func matches(_ record: MoveRecord, _ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            [record.title, record.project, record.computerName].compactMap { $0 }.contains { $0.localizedStandardContains(word) }
        }
    }

    var body: some View {
        let rows = model.movedRows.filter { Self.matches($0, query) }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { MovedRow(record: $0) }
            } header: {
                Text("Moved").foregroundStyle(Color(.secondaryLabel))
            }
        }
    }
}

/// What a moved row offers: Open once the session is listed on a computer this phone is paired with, Check Again while
/// nobody knows where it runs.
struct MovedActions: Equatable {
    var open: Route?
    var checks = false

    init(_ record: MoveRecord, root: AppRoot) {
        if record.state == .away, let there = root.model(for: record.computer),
           let landed = MoveLanding.session(for: record, in: there.sessions.sessions) {
            open = .session(landed.id, mac: there.macID)
        }
        checks = record.state == .unknown
    }
}

struct MovedRow: View {
    let record: MoveRecord
    @Environment(AppModel.self) private var model
    @Environment(AppRoot.self) private var root
    @Environment(SessionActions.self) private var actions
    @Environment(\.openSession) private var openSession

    private var offers: MovedActions { MovedActions(record, root: root) }
    private var paired: Bool { root.model(for: record.computer) != nil }

    var body: some View {
        HStack(alignment: .center, spacing: Space.s) {
            glyph.frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(MoveText.title(record))
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: Space.xxs) {
                    Image(systemName: record.agent.symbol).imageScale(.small)
                    Text(MoveText.status(record)).lineLimit(1)
                }
                .font(.subheadline)
            }
            .foregroundStyle(.secondary)
            Spacer(minLength: Space.xs)
            button
        }
        .padding(.vertical, 6)
        .frame(minHeight: 52)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(MoveText.title(record)), \(MoveText.status(record))")
        .accessibilityActions { actionButtons }
        .contextMenu {
            actionButtons
            Button("Copy Session ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = record.conversationID }
        }
    }

    @ViewBuilder private var glyph: some View {
        switch record.state {
        case .moving: ProgressView().controlSize(.small)
        case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.tertiary)
        default: Image(systemName: root.model(for: record.computer)?.mac.symbol ?? "desktopcomputer").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var button: some View {
        if offers.checks {
            Button("Check Again") { actions.on(model).checkMove(record) }
                .disabled(actions.isBusy("check-\(record.id)"))
                .capsule()
        } else if record.state == .away, paired {
            Button("Open") { if let route = offers.open { openSession?(route) } }
                .disabled(offers.open == nil)
                .capsule()
        }
    }

    @ViewBuilder private var actionButtons: some View {
        if let route = offers.open {
            Button("Open on \(record.computerName)", systemImage: "arrow.up.forward.app") { openSession?(route) }
        }
        if offers.checks {
            Button("Check Again", systemImage: "arrow.clockwise") { actions.on(model).checkMove(record) }
        }
    }
}

/// In place of the field of a conversation that is moving or has moved: nothing typed here can reach it, so the bar says
/// where it is and opens it there.
struct MoveStatusLine: View {
    let record: MoveRecord
    let sessionID: SessionKey
    @Environment(AppModel.self) private var model
    @Environment(AppRoot.self) private var root
    @Environment(SessionActions.self) private var actions
    @Environment(\.openSession) private var openSession

    /// The move that holds this conversation, while one does: the same rule as the list's moved rows.
    static func record(for conversation: String?, in model: AppModel) -> MoveRecord? {
        conversation.flatMap { conversation in model.movedRows.first { $0.conversationID == conversation } }
    }

    var body: some View {
        let offers = MovedActions(record, root: root)
        GlassEffectContainer(spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Label {
                    Text(MoveText.status(record)).lineLimit(1)
                } icon: {
                    if record.state == .moving {
                        ProgressView()
                    } else {
                        Image(systemName: record.state == .unknown ? "questionmark.circle" : "desktopcomputer")
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 50)
                .glassEffect(.regular, in: .capsule)
                if let route = offers.open {
                    Button("Open") { open(route) }.buttonStyle(.glassProminent)
                } else if offers.checks {
                    Button("Check Again") { actions.on(model).checkMove(record) }
                        .buttonStyle(.glass)
                        .disabled(actions.isBusy("check-\(record.id)"))
                }
            }
            .controlSize(.large)
        }
        .padding(.horizontal, Space.m)
        .padding(.bottom, Space.xs)
    }

    /// What was typed here and not sent goes with it.
    private func open(_ route: Route) {
        if case .session(let landed, let mac) = route, let there = root.model(for: mac) { model.handDraft(of: sessionID, to: there, as: landed) }
        openSession?(route)
    }
}

private extension View {
    func capsule() -> some View {
        font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
    }
}
