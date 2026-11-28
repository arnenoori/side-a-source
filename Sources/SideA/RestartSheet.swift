import SideAProtocol
import SwiftUI

/// Restart Fresh: the phone's handoff draft to edit, then a new hosted session with it as the first prompt. The old
/// session ends only once the new one is up.
struct RestartSheet: View {
    let model: SessionStore
    let session: LiveSession
    @Environment(\.dismiss) private var dismiss
    @State private var handoff: Handoff?
    @State private var failure: String?
    @State private var starting = false
    @State private var options: [AgentOptions] = []
    @State private var agent: AgentProvider?
    @State private var modelID = ""

    private var chosen: AgentProvider { agent ?? session.provider }
    /// The other agent can take over when it is installed and signed in on this Mac.
    private var others: [AgentProvider] { options.filter { $0.agent != session.provider && $0.installed && $0.signedIn != false }.map(\.agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Restart Fresh").font(.system(size: 15, weight: .semibold))
                Text("A new session starts with this handoff as its first prompt; this one ends once it's up.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let binding = Binding($handoff) {
                field("Goal", text: binding.goal, lines: 3)
                field("What failed", text: binding.failed, lines: 2)
                field("Next steps", text: binding.next, lines: 2)
                DisclosureGroup("Last messages") {
                    ScrollView {
                        Text(binding.wrappedValue.lastMessages).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                }
                .font(.system(size: 12))
            } else if let failure {
                Label(failure, systemImage: "exclamationmark.circle").font(.system(size: 12.5)).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            }
            if handoff != nil, let failure {
                Label(failure, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.red)
            }
            HStack {
                if handoff != nil, !options.isEmpty {
                    if !others.isEmpty {
                        Picker("Continue with", selection: Binding(get: { chosen }, set: { agent = $0 == session.provider ? nil : $0; modelID = "" })) {
                            ForEach([session.provider] + others, id: \.self) { Text(NewSessionSheet.name($0)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        .help("Hand the work to the other agent")
                    }
                    Picker("Model", selection: $modelID) {
                        Text("Same model").tag("")
                        ForEach(options.first { $0.agent == chosen }?.models ?? [], id: \.id) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(starting ? "Starting…" : chosen == session.provider ? "Restart" : "Hand Off to \(NewSessionSheet.name(chosen))") { restart() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(handoff == nil || starting)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await load() }
    }

    private func field(_ title: String, text: Binding<String>, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            TextField(title, text: text, axis: .vertical).lineLimit(lines...max(lines, 6)).textFieldStyle(.roundedBorder)
        }
    }

    private func load() async {
        do throws(SessionCommands.Failure) {
            handoff = try await SessionCommands(store: model.store).handoff(WireBuilders.key(session))
        } catch { failure = error.macMessage }
        options = await RemoteOptions.agents(model.store.remote) ?? []
    }

    private func restart() {
        guard let handoff else { return }
        starting = true
        failure = nil
        let app = model.resumeTerminal
        Task {
            do throws(SessionCommands.Failure) {
                let name = try await SessionCommands(store: model.store).restart(WireBuilders.key(session), RestartRequest(handoff: handoff, model: modelID.isEmpty ? nil : modelID, agent: agent), origin: "mac")
                model.attach(name, cwd: handoff.cwd, in: app)
                dismiss()
            } catch {
                failure = error.macMessage
                starting = false
            }
        }
    }
}
