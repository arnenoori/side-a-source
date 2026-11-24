import SideAProtocol
import SideARemoteKit
import SwiftUI

/// Must match the Mac's HandoffText, which writes these.
enum HandoffMessage {
    static let openings = ["This continues work ", "You handed this conversation off to "]
    /// The closing sentence with the heading after it, so a "## Message" in the typed message itself doesn't count.
    static let heading = "What to do now is the message below.\n\n## Message\n\n"

    static func isHandoff(_ text: String?) -> Bool { openings.contains { text?.hasPrefix($0) == true } }

    static func personal(_ text: String?) -> String? {
        guard let text, isHandoff(text), let range = text.range(of: heading) else { return nil }
        let message = String(text[range.upperBound...])
        return message.isEmpty ? nil : message
    }

    static func name(_ agent: AgentProvider, model: String?, tools: MacTools) -> String {
        let title = model.map { id in tools.models(for: agent).first { $0.id == id || $0.title == id }?.title ?? ModelName.short(id) }
        return [agent.title, title].compactMap { $0 }.joined(separator: " ")
    }
}

struct HandoffPendingLine: View {
    let session: RemoteSession
    let draft: HandoffDraft
    let review: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.xs) {
            Button(action: review) {
                HStack(spacing: Space.xxs) {
                    Image(systemName: "arrow.left.arrow.right")
                    Text("Hands off to \(draft.agent.title) when you send · Review")
                    Image(systemName: "chevron.forward").font(.caption.weight(.semibold))
                }
                .frame(minHeight: 32)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows what \(draft.agent.title) will be given")
            Button("Keep \(session.agent.title)", systemImage: "xmark.circle.fill") { model.handoffs.move(session.id, .dropped) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .hitArea(horizontal: Space.xs, vertical: Space.xs)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.m)
    }
}

struct HandoffHeader: View {
    let session: RemoteSession
    let link: HandoffLink
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var earlier: [TranscriptMessage] = []
    @State private var before: Cursor?
    @State private var count: Int?
    @State private var shown = false
    @State private var loading = false
    @State private var prompt: PromptState?

    private struct PromptState: Identifiable {
        let id: String
        var text: String?
        var error: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if shown {
                if before != nil {
                    Button("Load earlier") { Task { await load() } }
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .onAppear { Task { await load() } }
                }
                ForEach(earlier.filter { ($0.role == .user || $0.role == .assistant) && !($0.text ?? "").isEmpty }) { message in
                    if message.role == .user {
                        Text(message.text ?? "")
                            .padding(.horizontal, Space.m)
                            .padding(.vertical, Space.s)
                            .background(Color(.secondarySystemFill), in: .rect(cornerRadius: Radius.userBubble, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .textSelection(.enabled)
                    } else {
                        MarkdownView(message.text ?? "", sourceID: "handoff-\(link.conversationID)-\(message.seq)")
                    }
                }
            } else {
                Button {
                    withAnimation(Motion.smooth(reduceMotion)) { shown = true }
                    if earlier.isEmpty { Task { await load() } }
                } label: {
                    Text("Earlier with \(link.agent.title)" + (count.map { " · \($0) messages" } ?? ""))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: .capsule)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            divider
        }
        // Again once the Mac is back, for a count that couldn't be read while it was away.
        .task(id: "\(link.conversationID) \(model.tools.isLive)") { await peek() }
        .sheet(item: $prompt) { state in HandoffPromptSheet(title: dividerText, text: state.text, error: state.error) }
    }

    private var dividerText: String {
        "\(HandoffMessage.name(link.agent, model: link.model, tools: model.tools)) → "
            + HandoffMessage.name(session.agent, model: model.tools.settings(of: session).model, tools: model.tools)
    }

    private var divider: some View {
        HStack(spacing: Space.xs) {
            Rectangle().fill(.separator).frame(height: 1)
            Button {
                prompt = PromptState(id: link.id)
                Task { await fetchPrompt() }
            } label: {
                HStack(spacing: Space.xxs) {
                    Text(dividerText + (link.prompt ? " · Handoff" : ""))
                    if link.prompt { Image(systemName: "chevron.forward").font(.caption2.weight(.semibold)) }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .disabled(!link.prompt)
            .accessibilityHint(link.prompt ? "Shows the prompt \(session.agent.title) was given" : "")
            Rectangle().fill(.separator).frame(height: 1)
        }
    }

    private func peek() async {
        guard count == nil, model.tools.isLive else { return }
        guard let page = try? await model.tools.earlierPage(link.conversationID, before: nil) else { return }
        earlier = page.messages
        before = page.before
        count = page.count
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await model.tools.earlierPage(link.conversationID, before: before)
            let known = Set(earlier.map(\.seq))
            earlier = page.messages.filter { !known.contains($0.seq) } + earlier
            before = page.before
            count = page.count
        } catch {
            // Nothing to show: the button comes back for another try.
            if earlier.isEmpty { withAnimation(Motion.smooth(reduceMotion)) { shown = false } }
        }
    }

    private func fetchPrompt() async {
        do {
            let text = try await model.tools.handoffPrompt(link.id)
            if prompt?.id == link.id { prompt?.text = text }
        } catch {
            if prompt?.id == link.id { prompt?.error = MacTools.message(error) }
        }
    }
}

private struct HandoffPromptSheet: View {
    let title: String
    let text: String?
    let error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let text {
                    ScrollView { MarkdownView(text, sourceID: "handoff-prompt").padding(Space.m) }
                } else if let error {
                    ContentUnavailableView("No Handoff", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    DelayedProgress()
                }
            }
            .navigationTitle("Handoff")
            .navigationSubtitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() }.keyboardShortcut(.cancelAction) }
                if let text {
                    ToolbarItem(placement: .primaryAction) { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text } }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct HandoffFirstTurn: View {
    let message: String

    var body: some View {
        Text(message)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(Color(.secondarySystemFill), in: .rect(cornerRadius: Radius.userBubble, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .textSelection(.enabled)
            .accessibilityLabel("You: \(message)")
    }
}
