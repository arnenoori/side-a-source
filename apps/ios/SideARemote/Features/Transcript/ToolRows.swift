import SideAProtocol
import SideARemoteShared
import SwiftUI

struct ToolLabel: Hashable {
    let verb: String
    let target: String?
    let mono: Bool

    init(_ tool: TranscriptTool) {
        let running = tool.status == .running
        func pick(_ past: String, _ present: String) -> String { running ? present : past }
        switch tool.action {
        case .command(let command):
            verb = pick("Ran", "Running"); target = command; mono = true
        case .read(let path):
            verb = pick("Read", "Reading"); target = (path as NSString).lastPathComponent; mono = true
        case .edit(let path, _, _):
            verb = pick("Edited", "Editing"); target = (path as NSString).lastPathComponent; mono = true
        case .write(let path, _):
            verb = pick("Wrote", "Writing"); target = (path as NSString).lastPathComponent; mono = true
        case .patch(let files, _):
            verb = pick("Edited", "Editing"); target = files.count == 1 ? (files[0] as NSString).lastPathComponent : "\(files.count) files"; mono = files.count == 1
        case .fetch(let url):
            verb = pick("Fetched", "Fetching"); target = URL(string: url)?.host() ?? url; mono = true
        case .search(let query):
            if tool.name == "Glob" || tool.name == "LS" {
                verb = pick("Listed", "Listing"); target = query; mono = true
            } else if tool.name == "WebSearch" {
                verb = pick("Searched the web for", "Searching the web for"); target = query; mono = false
            } else {
                verb = pick("Searched", "Searching"); target = "\u{201C}\(query.replacingOccurrences(of: " in Sources", with: ""))\u{201D}"; mono = true
            }
        case .mcp(_, let name, _):
            verb = pick("Used", "Using"); target = name; mono = true
        default:
            switch tool.name {
            case "Thinking":
                verb = running ? "Thinking" : "Thought"; target = nil; mono = false
            case "Task", "Agent":
                verb = pick("Asked a subagent to", "Asking a subagent to"); target = tool.summary.lowercasedFirst; mono = false
            case "TodoWrite", "update_plan":
                verb = pick("Updated the plan", "Updating the plan"); target = nil; mono = false
            default:
                verb = pick("Used", "Using"); target = tool.name; mono = true
            }
        }
    }

    var accessibilityText: String { [verb, target].compactMap { $0 }.joined(separator: " ") }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

extension TranscriptTool {
    var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return endedAt - startedAt
    }
}

struct ToolRow: View {
    let sessionID: SessionKey
    let tool: TranscriptTool

    var body: some View {
        NavigationLink(value: Route.step(sessionID, tool)) {
            ToolRowLabel(tool: tool)
        }
        .buttonStyle(.plain)
        .zoomSource(tool.id)
        .contextMenu {
            if case .command(let command) = tool.action {
                Button("Copy Command", systemImage: "doc.on.doc") { UIPasteboard.general.string = command }
            } else if let path = tool.action?.path {
                Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
            }
            if let output = tool.output {
                Button("Copy Output", systemImage: "text.alignleft") { UIPasteboard.general.string = output }
            }
        }
    }
}

struct ToolRowLabel: View {
    let tool: TranscriptTool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let label = ToolLabel(tool)
        let running = tool.status == .running
        HStack(spacing: Space.s) {
            Image(systemName: ToolGlyph.symbol(for: tool.name))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative, options: .repeat(.continuous), isActive: running && !reduceMotion)
                .frame(width: 22)
            sentence(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                // One line: a wrapped file name gets hyphenated mid-word.
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
            Spacer(minLength: Space.xs)
            trailing
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.accessibilityText + (tool.duration.flatMap { Formatting.duration($0) }.map { ", \($0)" } ?? "")
                            + (tool.status == .failed ? ", failed" : ""))
        .accessibilityHint("Opens details")
        .accessibilityAddTraits(.isButton)
    }

    private func sentence(_ label: ToolLabel) -> Text {
        var text = Text(label.verb).fontWeight(.medium)
        if let target = label.target {
            text = text + Text(" ") + (label.mono ? Text(target).font(.subheadline.monospaced()) : Text(target))
        }
        return text
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: Space.xs) {
            if tool.status == .failed {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.destructive)
            } else if let duration = tool.duration, let text = Formatting.duration(duration) {
                Text(text).font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

extension IslandAction {
    var path: String? {
        switch self {
        case .read(let path), .edit(let path, _, _), .write(let path, _): path
        default: nil
        }
    }
}

struct QuietDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.smooth(reduceMotion)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: Space.s) {
                    configuration.label
                    Spacer(minLength: Space.xs)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "expanded" : "collapsed")
            if configuration.isExpanded {
                HStack(alignment: .top, spacing: 0) {
                    Rectangle().fill(Color(.separator)).frame(width: 1)
                        .padding(.leading, 10)
                    configuration.content
                        .padding(.leading, Space.s)
                }
                .transition(.opacity)
            }
        }
    }
}

struct ThinkingRow: View {
    let tool: TranscriptTool
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if (tool.output ?? "").isEmpty {
            label.frame(minHeight: 44).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                Text(tool.output ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.vertical, Space.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                label
            }
            .disclosureGroupStyle(QuietDisclosureStyle())
        }
    }

    private var label: some View {
        let running = tool.status == .running
        return HStack(spacing: Space.s) {
            Image(systemName: "brain")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeat(.continuous), isActive: running && !reduceMotion)
                .frame(width: 22)
            if running, let start = tool.startedAt {
                (Text("Thinking · ").fontWeight(.medium) + Text(timerInterval: Date(timeIntervalSince1970: start)...Date.distantFuture, countsDown: false))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Thought for \(Formatting.duration(max(tool.duration ?? 1, 1)) ?? "1s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(running ? "Thinking" : "Thought for \(Int(max(tool.duration ?? 1, 1).rounded())) seconds")
    }
}

struct StepGroupRow: View {
    let sessionID: SessionKey
    let group: StepGroup
    @State private var expanded: Bool

    init(sessionID: SessionKey, group: StepGroup) {
        self.sessionID = sessionID
        self.group = group
        expanded = TranscriptLayout.startsExpanded(group)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 0) {
                let shown = group.running ? Array(group.tools.suffix(3)) : group.tools
                if group.running, group.tools.count > 3 {
                    Text("\(group.tools.count - 3) more")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(minHeight: 32)
                }
                ForEach(shown) { tool in
                    if tool.name == "Thinking" { ThinkingRow(tool: tool) } else { ToolRow(sessionID: sessionID, tool: tool) }
                }
            }
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: "square.stack.3d.up")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(group.title)
                    .font(.subheadline.monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
        }
        .disclosureGroupStyle(QuietDisclosureStyle())
    }
}

struct TurnEndRow<More: View>: View {
    let end: TurnEnd
    let text: String
    @ViewBuilder var more: More
    @State private var copies = 0
    @State private var showsCheck = false

    init(end: TurnEnd, text: String, @ViewBuilder more: () -> More = { EmptyView() }) {
        self.end = end
        self.text = text
        self.more = more()
    }

    var body: some View {
        HStack(spacing: Space.xxs) {
            Button("Copy", systemImage: showsCheck ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = text
                copies += 1
            }
            .contentTransition(.symbolEffect(.replace))
            .sensoryFeedback(.success, trigger: copies)
            ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
            more
            Spacer(minLength: Space.l)
            Text([end.model, end.duration.flatMap { Formatting.duration($0) }].compactMap { $0 }.joined(separator: " · "))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .labelStyle(IconTarget(size: CGSize(width: 32, height: 32), horizontal: 2, vertical: 6))
        .font(.subheadline)
        .foregroundStyle(.tertiary)
        .buttonStyle(.plain)
        .frame(height: 32)
        .task(id: copies) {
            guard copies > 0 else { return }
            showsCheck = true
            try? await Task.sleep(for: .seconds(1.5))
            showsCheck = false
        }
    }
}
