import SideAProtocol
import SideASessionKit
import SwiftUI

extension PullRequest {
    var summary: String {
        let name = number.map { "#\($0)" } ?? "Pull request"
        switch (state, checks) {
        case (.merged?, _): return "\(name) · merged"
        case (.closed?, _): return "\(name) · closed"
        case (_, .failing?): return "\(name) · checks failing"
        case (_, .pending?): return "\(name) · checks running"
        case (_, .passing?): return "\(name) · checks passing"
        case (.draft?, _): return "\(name) · draft"
        default: return name
        }
    }

    var tint: Color {
        switch (state, checks) {
        case (.merged?, _): .done
        case (.closed?, _), (.draft?, nil): Color(.tertiaryLabel)
        case (_, .failing?): .destructive
        case (_, .passing?): .done
        default: Color(.secondaryLabel)
        }
    }

    var symbol: String {
        switch (state, checks) {
        case (.merged?, _): "arrow.triangle.merge"
        case (.closed?, _): "xmark.circle"
        case (_, .failing?): "xmark.circle.fill"
        case (_, .pending?): "clock"
        case (_, .passing?): "checkmark.circle.fill"
        default: "arrow.triangle.pull"
        }
    }

    var link: URL? { URL(string: url).flatMap { $0.scheme == "https" ? $0 : nil } }
}

struct PullRequestChip: View {
    let pull: PullRequest
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let link = pull.link { openURL(link) }
        } label: {
            HStack(spacing: Space.xxs) {
                Image(systemName: pull.symbol).foregroundStyle(pull.tint).imageScale(.small)
                Text(pull.summary).foregroundStyle(.primary).lineLimit(1)
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, Space.xs)
            .frame(minHeight: 28)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .contextMenu { PullRequestMenu(pull: pull) }
        .accessibilityLabel(pull.title.map { "\(pull.summary), \($0)" } ?? pull.summary)
        .accessibilityHint("Opens the pull request. Touch and hold to copy its link.")
    }
}

struct PullRequestMenu: View {
    let pull: PullRequest
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let link = pull.link {
            Button("Open Pull Request", systemImage: "arrow.up.forward.square") { openURL(link) }
        }
        Button("Copy Pull Request Link", systemImage: "link") {
            UIPasteboard.general.string = pull.url
            Pill.show("Link copied")
        }
    }
}

struct PullRequestBadge: View {
    let pull: PullRequest
    var compact = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: pull.symbol).foregroundStyle(pull.tint).imageScale(.small)
            Text(compact ? (pull.number.map { "#\($0)" } ?? "Pull request") : pull.summary)
        }
        .font(.footnote)
        .lineLimit(1)
        .fixedSize()
    }
}

extension SessionFailure {
    var symbol: String {
        switch kind {
        case .contextFull: "text.badge.xmark"
        case .folderPermission: "lock.shield"
        case .signedOut: "person.crop.circle.badge.exclamationmark"
        case .gitAuth: "key.slash"
        default: "exclamationmark.triangle"
        }
    }
}

struct FailureFixButton: View {
    let session: RemoteSession
    let failure: SessionFailure
    @Environment(AppModel.self) private var model

    var body: some View {
        switch failure.fix {
        case .compact?:
            if session.abilities.contains(.compact) {
                CompactButton(session: session)
            } else if session.hosted != nil || session.abilities.contains(.replyTyped) {
                // Claude has no compact call; typed into its prompt, /compact does the same.
                Button("Compact", systemImage: "arrow.down.right.and.arrow.up.left") { model.reply("/compact", to: session.id) }
                    .needsMac()
            }
        case .terminal?:
            TerminalButton(session: session, title: "Open Terminal")
        default:
            EmptyView()
        }
    }
}

struct FailureSection: View {
    let session: RemoteSession
    let failure: SessionFailure

    var body: some View {
        Section {
            Label(failure.message, systemImage: failure.symbol)
                .foregroundStyle(failure.retryable ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.destructive))
            if let detail = failure.detail {
                Text(detail).font(.footnote.monospaced()).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
            }
            FailureFixButton(session: session, failure: failure)
        }
    }
}

extension RemoteSession {
    var snoozable: Bool {
        openRequests.isEmpty && status != .waiting && failure == nil && ![.failing, .stuck].contains(flag?.kind)
    }
}

struct SnoozeMenu: View {
    let session: RemoteSession
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if model.tools.can(.snooze), session.snoozable {
            if model.tools.snooze(of: session) != nil {
                Button("Wake", systemImage: "sun.max") { actions.on(model).snooze(session, nil) }
            } else {
                Menu("Snooze", systemImage: "moon.zzz") {
                    ForEach(SessionSnooze.Choice.offered, id: \.self) { choice in
                        Button(choice.title) { actions.on(model).snooze(session, choice) }
                    }
                }
            }
        }
    }
}
