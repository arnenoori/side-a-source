import SideACore
import SideAProtocol
import SwiftUI

/// New Session: the phone's choices (agent, folder, model, effort, account, worktree, first prompt) from the same
/// lists, started by the same command. Account and worktree need Side A's hosting; without it the agent opens in a
/// terminal tab with Side A's usual account.
struct NewSessionSheet: View {
    let model: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var agent: AgentProvider = .claude
    @State private var projects: [RemoteProject]?
    @State private var options: [AgentOptions] = []
    @State private var cwd = ""
    @State private var modelID = ""
    @State private var effort = Effort.auto.rawValue
    @State private var accountID = ""
    @State private var worktree = false
    @State private var prompt = ""
    @State private var failure: String?
    @State private var starting = false

    private var store: AccountStore { model.store }
    private var hosting: Bool { store.hostingWanted && store.hosted.available }
    private var mine: AgentOptions? { options.first { $0.agent == agent } }
    private var chosen: ModelOption? { mine?.models.first { $0.id == modelID } }
    private var project: RemoteProject? { projects?.first { $0.path == cwd } }
    private var accounts: [Account] { store.config.accounts.filter { $0.provider == agent && $0.ready } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Session").font(.system(size: 15, weight: .semibold))
            Form {
                Picker("Agent", selection: $agent) {
                    ForEach(options.filter(\.installed).map(\.agent), id: \.self) { Text($0 == .codex ? "Codex" : "Claude Code").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Folder", selection: $cwd) {
                    if projects == nil { Text("Loading…").tag("") }
                    ForEach(projects ?? []) { project in
                        Text(project.branch.map { "\(project.name)  ·  \($0)" } ?? project.name).tag(project.path)
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
                if hosting {
                    Picker("Account", selection: $accountID) {
                        Text("Autopilot's pick").tag("")
                        ForEach(accounts) { account in Text(Self.account(account, usage: store.usage[account.id])).tag(account.id) }
                    }
                    if project?.gitRoot != nil { Toggle("In a new worktree", isOn: $worktree) }
                }
                TextField("First prompt", text: $prompt, prompt: Text("Optional"), axis: .vertical).lineLimit(3...8)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            if !hosting {
                Text("Opens in \(model.resumeTerminal.title) with Side A's usual account. Turn on terminal hosting or Remote to pick the account or a worktree.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
        .task { await load() }
        .onChange(of: agent) {
            modelID = ""
            effort = Effort.auto.rawValue
            accountID = ""
        }
        .onChange(of: modelID) { if let efforts = chosen?.efforts, !efforts.map(\.rawValue).contains(effort) { effort = Effort.auto.rawValue } }
    }

    /// "Work · 5h 42%", or just the name before its usage is read.
    static func account(_ account: Account, usage: AccountUsage?) -> String {
        guard let window = usage?.fiveHour ?? usage?.windows.first else { return account.name }
        return "\(account.name)  ·  \(window.label) \(window.text(at: Date().timeIntervalSince1970))"
    }

    private func load() async {
        async let found = RemoteRoutes.projectList(store.remote)
        async let agents = RemoteRoutes.agentOptions(store.remote)
        options = await agents ?? []
        projects = await found
        if cwd.isEmpty { cwd = projects?.first?.path ?? "" }
        if !(options.first { $0.agent == agent }?.installed ?? false), let first = options.first(where: \.installed) { agent = first.agent }
    }

    private func start() {
        starting = true
        failure = nil
        let start = StartHosted(cwd: cwd, agent: agent, model: modelID.isEmpty ? nil : modelID,
                                effort: effort == Effort.auto.rawValue ? nil : effort, worktree: hosting && worktree,
                                accountID: hosting && !accountID.isEmpty ? accountID : nil, prompt: prompt.isEmpty ? nil : prompt)
        model.start(start) { error in
            starting = false
            if let error { failure = error } else { dismiss() }
        }
    }
}
