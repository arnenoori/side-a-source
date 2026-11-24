import SideAProtocol
import SideARemoteKit
import SwiftUI

struct RestartSheet: View {
    let session: RemoteSession
    var review: HandoffDraft?
    var message = ""
    let onRestarted: (HostedSession) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Handoff?
    @State private var original: Handoff?
    @State private var error: String?
    @State private var previewing = false
    @State private var restarting = false
    @State private var confirmingStop = false
    @State private var discarding = false
    @State private var restarted = 0
    @State private var key = SendKey<Handoff>()

    private var edited: Bool { draft != original }
    private var models: [ModelOption] { model.tools.models(for: session.agent) }
    private var accounts: [RemoteAccount] { model.accounts.accounts.filter { $0.provider == session.agent } }

    var body: some View {
        NavigationStack {
            Group {
                if let draft = Binding($draft) {
                    if previewing {
                        ScrollView {
                            MarkdownView(review == nil ? Self.markdown(draft.wrappedValue) : Self.reviewMarkdown(draft.wrappedValue, message: message),
                                         sourceID: "handoff").padding(Space.m)
                        }
                    } else {
                        form(draft)
                    }
                } else if let error {
                    ContentUnavailableView("No Handoff", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView("Drafting the handoff…")
                }
            }
            .navigationTitle(review.map { "Hand Off to \($0.agent.title)" } ?? "Restart Fresh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { edited ? (discarding = true) : dismiss() }.keyboardShortcut(.cancelAction)
                        .confirmationDialog("Discard your changes?", isPresented: $discarding) {
                            Button("Discard Changes", role: .destructive) { dismiss() }
                        }
                }
                if draft != nil {
                    ToolbarItem(placement: .principal) {
                        Picker("View", selection: $previewing) {
                            Text("Edit").tag(false)
                            Text("Preview").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if review != nil {
                            Button("Done", systemImage: "checkmark") { keepReview() }
                                .buttonStyle(.glassProminent)
                        } else if restarting {
                            ProgressView()
                        } else {
                            Button("Restart") { session.status == .working ? (confirmingStop = true) : restart() }
                                .buttonStyle(.glassProminent)
                                .confirmationDialog("It's still working. Stop it and restart?", isPresented: $confirmingStop,
                                                    titleVisibility: .visible) {
                                    Button("Stop and Restart", role: .destructive) { restart() }
                                }
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(edited || restarting)
        .sensoryFeedback(.success, trigger: restarted)
        .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        .task { await load() }
    }

    private func form(_ draft: Binding<Handoff>) -> some View {
        Form {
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            Section("Goal") { TextField("What it's for", text: draft.goal, axis: .vertical) }
            Section("Branch") {
                TextField("Branch", text: Binding { draft.wrappedValue.branch ?? "" } set: { draft.wrappedValue.branch = $0.isEmpty ? nil : $0 })
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("What Failed") { TextField("Nothing yet", text: draft.failed, axis: .vertical) }
            Section("Next Steps") { TextField("Where to pick up", text: draft.next, axis: .vertical) }
            if let review {
                reviewSections(draft.wrappedValue, review: review)
            } else {
                Section("Last Messages") {
                    TextField("", text: draft.lastMessages, axis: .vertical)
                        .font(.callout)
                        .lineLimit(3...12)
                }
                sameAgentSection(draft)
            }
        }
    }

    @ViewBuilder
    private func reviewSections(_ draft: Handoff, review: HandoffDraft) -> some View {
        if let plan = draft.plan, !plan.steps.isEmpty {
            Section("Plan") {
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                    Label(step.text, systemImage: step.status == .completed ? "checkmark.circle.fill" : step.status == .inProgress ? "circle.dotted" : "circle")
                }
            }
        }
        if let changes = draft.changes, !changes.isEmpty {
            Section("Changed Files") {
                Text(changes)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        }
        Section {
            LabeledContent("Agent", value: HandoffMessage.name(review.agent, model: review.modelID, tools: model.tools))
            if let effort = review.effort { LabeledContent("Effort", value: effort.title) }
            if let account = review.accountID.flatMap({ id in model.accounts.accounts.first { $0.id == id } }) {
                LabeledContent("Account", value: account.name)
            }
            LabeledContent("Folder", value: "Same folder · \(draft.project)")
        } header: {
            Text("Hands Off To")
        }
        Section {
            Text(message.isEmpty ? "Type it in the message field." : message)
                .foregroundStyle(message.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
        } header: {
            Text("Your Message")
        }
    }

    private func sameAgentSection(_ draft: Binding<Handoff>) -> some View {
        Section {
            if accounts.count > 1 {
                Picker("Account", selection: draft.accountID) {
                    Text("Auto").tag(String?.none)
                    ForEach(accounts) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if !models.isEmpty {
                Picker("Model", selection: draft.model) {
                    Text("Default").tag(String?.none)
                    ForEach(models, id: \.id) { Text($0.title).tag(Optional($0.id)) }
                }
            }
            LabeledContent("Folder", value: "Same folder · \(draft.wrappedValue.project)")
        }
    }

    private func keepReview() {
        if let draft { model.handoffs.move(session.id, .reviewed(draft)) }
        dismiss()
    }

    static func reviewMarkdown(_ handoff: Handoff, message: String) -> String {
        var parts = [markdown(Handoff(goal: handoff.goal, branch: handoff.branch, failed: handoff.failed, next: handoff.next, lastMessages: "",
                                      cwd: handoff.cwd, project: handoff.project))]
        if let changes = handoff.changes, !changes.isEmpty { parts.append("## Changed files\n\n```\n\(changes)\n```") }
        if let plan = handoff.plan, !plan.steps.isEmpty {
            parts.append("## Plan\n\n" + plan.steps.map { "- [\($0.status == .completed ? "x" : " ")] \($0.text)" }.joined(separator: "\n"))
        }
        if !message.isEmpty { parts.append("## Message\n\n\(message)") }
        return parts.joined(separator: "\n\n")
    }

    static func markdown(_ handoff: Handoff) -> String {
        var parts = ["## Goal\n\n\(handoff.goal)"]
        if let branch = handoff.branch, !branch.isEmpty { parts.append("## Branch\n\n`\(branch)`") }
        if !handoff.failed.isEmpty { parts.append("## What failed\n\n\(handoff.failed)") }
        if !handoff.next.isEmpty { parts.append("## Next steps\n\n\(handoff.next)") }
        if !handoff.lastMessages.isEmpty { parts.append("## Last messages\n\n\(handoff.lastMessages)") }
        return parts.joined(separator: "\n\n")
    }

    private func load() async {
        guard draft == nil else { return }
        async let options: Void = model.tools.loadOptions()
        if review != nil, let kept = model.handoffs[session.id]?.handoff {
            draft = kept
            original = kept
            await options
            return
        }
        do {
            let handoff = try await model.tools.handoff(session.id)
            draft = handoff
            original = handoff
        } catch {
            self.error = MacTools.message(error)
        }
        await options
    }

    private func restart() {
        guard let draft else { return }
        restarting = true
        error = nil
        let sent = key.sending(draft)
        Task {
            defer { restarting = false }
            do {
                let hosted = try await model.tools.restart(session.id, draft, key: sent)
                key.answered()
                restarted += 1
                dismiss()
                onRestarted(hosted)
            } catch let failure as RemoteFailure where failure.error.code == .outcomeUnknown {
                key.answered()
                error = "This may or may not have reached \(model.mac.name). Check Sessions before restarting again."
            } catch let failure as RemoteFailure {
                key.answered()
                error = MacTools.message(failure)
            } catch {
                self.error = MacTools.message(error)
            }
        }
    }
}
