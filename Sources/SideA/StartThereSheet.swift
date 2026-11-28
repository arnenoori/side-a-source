import SideACore
import SideAProtocol
import SwiftUI

/// Starts a session on a linked computer, in one of its folders.
struct StartThereSheet: View {
    let model: SessionStore
    let computerID: String
    @Environment(\.dismiss) private var dismiss
    @State private var agent: AgentProvider = .claude
    @State private var projects: [RemoteProject]?
    @State private var options: [AgentOptions] = []
    @State private var unreachable: String?
    @State private var cwd = ""
    @State private var modelID = ""
    @State private var effort = Effort.auto.rawValue
    @State private var worktree = false
    @State private var prompt = ""
    @State private var failure: String?
    @State private var starting = false

    private var store: AccountStore { model.store }
    private var computers: [LinkedComputer] { store.remote.computers.all }
    /// Nil for this Mac.
    private var computer: LinkedComputer? { computers.first { $0.id == computerID } }
    private var mine: AgentOptions? { options.first { $0.agent == agent } }
    private var chosen: ModelOption? { mine?.models.first { $0.id == modelID } }
    private var project: RemoteProject? { projects?.first { $0.path == cwd } }
    private var offersWorktree: Bool { project?.gitRoot != nil && computer?.hostsTerminals == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Session on \(computer?.name ?? "Another Computer")").font(.system(size: 15, weight: .semibold))
            Form {
                Picker("Agent", selection: $agent) {
                    ForEach(options.filter(\.installed).map(\.agent), id: \.self) { Text($0 == .codex ? "Codex" : "Claude Code").tag($0) }
                }
                .pickerStyle(.segmented)
                if let unreachable {
                    LabeledContent("Folder") { Text(unreachable).foregroundStyle(.secondary) }
                } else {
                    Picker("Folder", selection: $cwd) {
                        if projects == nil { Text("Loading…").tag("") }
                        ForEach(projects ?? []) { project in
                            Text(project.branch.map { "\(project.name)  ·  \($0)" } ?? project.name).tag(project.path)
                        }
                    }
                }
                Picker("Model", selection: $modelID) {
                    Text("Default").tag("")
                    ForEach(mine?.models ?? [], id: \.id) { Text($0.title).tag($0.id) }
                }
                if let efforts = chosen?.efforts ?? (modelID.isEmpty && agent == .claude ? RemoteOptions.claudeBase : nil), !efforts.isEmpty {
                    Picker("Effort", selection: $effort) {
                        ForEach(efforts, id: \.rawValue) { Text($0 == .auto ? "Default" : $0.title).tag($0.rawValue) }
                    }
                }
                if offersWorktree { Toggle("In a new worktree", isOn: $worktree) }
                TextField("First prompt", text: $prompt, prompt: Text("Optional"), axis: .vertical).lineLimit(3...8)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            if let failure { Label(failure, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(starting ? "Starting…" : "Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cwd.isEmpty || starting)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task(id: computerID) { await load() }
        .onChange(of: agent) {
            modelID = ""
            effort = Effort.auto.rawValue
        }
        .onChange(of: modelID) { if let efforts = chosen?.efforts, !efforts.map(\.rawValue).contains(effort) { effort = Effort.auto.rawValue } }
    }

    /// The folders and agents of the computer chosen: this Mac's own, or what the other one answers.
    private func load() async {
        unreachable = nil
        failure = nil
        projects = nil
        cwd = ""
        if let computer {
            guard let peer = store.remote.computers.peer(computer.id, me: store.remote.mac) else {
                unreachable = "\(computer.name) isn’t linked any more."
                return
            }
            do {
                async let found = peer.projects()
                async let agents = peer.options()
                let (folders, offered) = try await (found, agents)
                guard !Task.isCancelled else { return }
                (projects, options) = (folders, offered)
            } catch {
                if !Task.isCancelled { unreachable = peer.sentence(error) }
                return
            }
        }
        if cwd.isEmpty { cwd = projects?.first?.path ?? "" }
        if !(options.first { $0.agent == agent }?.installed ?? false), let first = options.first(where: \.installed) { agent = first.agent }
        if !modelID.isEmpty, chosen == nil { modelID = "" }
    }

    private func start() {
        starting = true
        failure = nil
        let start = StartHosted(cwd: cwd, agent: agent, model: modelID.isEmpty ? nil : modelID,
                                effort: effort == Effort.auto.rawValue ? nil : effort, worktree: offersWorktree && worktree,
                                prompt: prompt.isEmpty ? nil : prompt)
        guard let computer else { return dismiss() }
        guard let peer = store.remote.computers.peer(computer.id, me: store.remote.mac) else {
            starting = false
            failure = "\(computer.name) isn’t linked any more."
            return
        }
        Task {
            do {
                let hosted = try await peer.startHosted(start)
                Sounds.play(.spinUp)
                // As a start here does: a tab attached to it.
                if computer.hostsTerminals { model.attachRemote(hosted.name, on: computer) }
                AccessibilityNotification.Announcement("Started on \(computer.name)").post()
                dismiss()
            } catch {
                failure = peer.sentence(error)
            }
            starting = false
        }
    }
}
