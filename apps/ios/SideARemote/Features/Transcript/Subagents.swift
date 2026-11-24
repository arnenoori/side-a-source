import SideAProtocol
import SideARemoteShared
import SwiftUI

struct SubagentCard: View {
    let sessionID: SessionKey
    let tool: TranscriptTool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var running: Bool { tool.status == .running }
    private var title: String { tool.subagent?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Subagent" }

    private var parent: SessionKey { SubagentRef(key: sessionID)?.parent ?? sessionID }

    private var route: Route {
        guard let agentID = tool.agentID else { return .step(sessionID, tool) }
        return .subagent(SubagentRef(parent: parent, agentID: agentID, title: title))
    }

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: Space.s) {
                glyph.frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    detail
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.xs)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Radius.inlineCard, style: .continuous))
            .contentShape(.rect(cornerRadius: Radius.inlineCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Motion.smooth(reduceMotion), value: tool.status)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Subagent, \(title), \(statusText)")
        .accessibilityHint(tool.agentID == nil ? "Opens details" : "Opens its transcript")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var glyph: some View {
        switch tool.status {
        case .running:
            Image(systemName: "person.2.wave.2")
                .font(.subheadline)
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, options: .repeat(.continuous), isActive: !reduceMotion)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.destructive)
        case .denied:
            Image(systemName: "nosign").foregroundStyle(.secondary)
        default:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    @ViewBuilder private var detail: some View {
        if running, let started = tool.startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Working · " + Formatting.elapsed(since: Date(timeIntervalSince1970: started), now: context.date))
                    .monospacedDigit()
            }
        } else {
            Text(statusText)
        }
    }

    private var statusText: String {
        switch tool.status {
        case .running: return "Working"
        case .failed: return "Failed"
        case .denied: return "Not allowed"
        default:
            if let line = tool.output?.split(whereSeparator: \.isNewline).lazy.map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
                return line
            }
            return tool.duration.flatMap { Formatting.duration($0) }.map { "Done in \($0)" } ?? "Done"
        }
    }
}

struct SubagentBar: View {
    let ref: SubagentRef
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: Space.s) {
            Label("Subagent · runs on its own", systemImage: "person.2.wave.2")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: Space.xs)
            Button("Open Parent", systemImage: "arrow.up.backward") { dismiss() }
                .buttonStyle(.glass)
                .labelStyle(.titleAndIcon)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.xs)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
