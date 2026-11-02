import SideACore
import SwiftUI

/// What `setup overview` reports. Env and header values never leave the bridge, only their names; URLs come
/// as scheme://host[:port] and commands as the program's name, since arguments can hold keys.
struct SetupOverview: Decodable, Sendable {
    struct Tool: Decodable, Sendable { let name: String; let path: String?; let version: String? }
    struct Server: Decodable, Sendable, Identifiable {
        let name: String, scope: String, type: String, target: String
        let env: [String], headers: [String]
        let project: String?, disabled: Bool?
        var id: String { "\(scope)|\(project ?? "")|\(name)" }
    }
    struct Hook: Decodable, Sendable {
        let agent: String, file: String, event: String, matcher: String?, command: String, sideA: String?
    }
    struct Skill: Decodable, Sendable { let name: String; let source: String }
    struct Agent: Decodable, Sendable { let name: String }
    let tools: [Tool]
    let mcpServers: [Server]
    let hooks: [Hook]
    let skills: [Skill]
    let agents: [Agent]

    static let demo = SetupOverview(
        tools: [Tool(name: "claude", path: "~/.local/bin/claude", version: "2.1.296"),
                Tool(name: "codex", path: "/opt/homebrew/bin/codex", version: "0.162.1")],
        mcpServers: [
            Server(name: "docs", scope: "user", type: "http", target: "https://mcp.example.com", env: [], headers: ["Authorization"], project: nil, disabled: nil),
            Server(name: "simulator", scope: "project", type: "stdio", target: "npx sim-mcp", env: ["SIM_TOKEN"], headers: [], project: "~/code/app", disabled: nil),
            Server(name: "tracker", scope: "codex", type: "http", target: "https://tracker.example.com", env: [], headers: [], project: nil, disabled: true)],
        hooks: [
            Hook(agent: "claude", file: "~/.claude/settings.json", event: "PermissionRequest", matcher: "*", command: "sh island-hook.sh", sideA: "Dynamic Island"),
            Hook(agent: "claude", file: "~/.claude/settings.json", event: "PostToolUse", matcher: "Edit|Write", command: "npx prettier", sideA: nil),
            Hook(agent: "codex", file: "~/.codex/hooks.json", event: "Stop", matcher: nil, command: "say", sideA: nil)],
        skills: ["code-review", "release-notes", "simplify"].map { Skill(name: $0, source: "claude") },
        agents: [Agent(name: "explorer"), Agent(name: "reviewer")])
    static let demoHealth = ["docs": "connected", "simulator": "failed"]
}

struct SetupSettings: View {
    @Bindable var store: AccountStore
    @State private var overview: SetupOverview?
    @State private var failure: String?
    @State private var health: [String: String] = [:]
    @State private var checking = false
    @State private var cleaning = false
    @AppStorage("setupInventoryShown") private var inventory = false

    var body: some View {
        Form {
            Section("Tools") {
                DependencyStatusView(store: store, provider: .claude)
                DependencyStatusView(store: store, provider: .codex, compact: true)
                ForEach(overview?.tools ?? [], id: \.name) { tool in
                    LabeledContent(tool.name == "claude" ? "Claude Code" : "Codex CLI") {
                        Text(tool.path.map { "\(tool.version ?? "unknown version") at \($0)" } ?? "Not installed")
                            .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }.font(.system(size: 12))
                }
            }
            Section {
                Toggle(isOn: Binding(get: { store.shellSwitching }, set: { value in Task { await store.setShellSwitching(value) } })) {
                    Text("Switch in Terminal")
                    Text("New claude commands use the account Autopilot picks; sidea use <name> keeps a tab on one. Adds a line to ~/.zshrc.")
                }
                Toggle(isOn: Binding(get: { store.hostTerminal }, set: { value in Task { await store.setHostTerminal(value) } })) {
                    Text("Host terminal sessions")
                    // tmux is only looked for once hosting is wanted, so before then the switch is offered.
                    Text(store.hosted.available || store.hostTerminal || !store.hostingWanted
                         ? "claude and codex typed in a terminal run in Side A's tmux, so your phone can join and closing the tab leaves them running; sidea attach brings one back. The tab's scrollback no longer holds the conversation. Adds a second line to ~/.zshrc."
                         : "Needs tmux 3.4 or later: brew install tmux, then reopen Side A.")
                }
                .disabled(!store.hosted.available && !store.hostTerminal && store.hostingWanted)
                Toggle(isOn: Binding(get: { store.liveLimits }, set: { value in Task { await store.setLiveLimits(value) } })) {
                    Text("Live limits from Claude Code")
                    Text("Each reply updates the numbers; your statusline keeps working.")
                }
                Toggle(isOn: Binding(get: { store.limitHook }, set: { value in Task { await store.setLimitHook(value) } })) {
                    Text("React the moment a limit hits")
                    Text("A silent Claude Code hook that rechecks right away.")
                }
            } header: {
                Text("Terminal")
            }
            Section {
                LabeledContent("Old conversations and worktrees") {
                    Button("Clean Up…") { cleaning = true }
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("See what your conversations take on disk, archive old ones and remove worktrees your sessions left behind.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure { Section { Text(failure).foregroundStyle(.secondary) } }
            if let overview {
                Section {
                    LabeledContent {
                        Button(inventory ? "Hide" : "Show") { inventory.toggle() }
                    } label: {
                        Text("Claude Code setup")
                        Text("\(overview.mcpServers.count) MCP servers, \(overview.hooks.count) hooks, \(overview.skills.count) skills, \(overview.agents.count) agents")
                    }
                }
                if inventory {
                    servers(overview.mcpServers)
                    hooks(overview.hooks)
                    Section("Skills and agents") {
                        names("Skills", overview.skills.map { $0.source == "claude" || $0.source == "agents" ? $0.name : "\($0.name) (\($0.source))" })
                        names("Agents", overview.agents.map(\.name))
                    }
                }
            } else if failure == nil {
                Section { ProgressView().controlSize(.small) }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
        .sheet(isPresented: $cleaning, onDismiss: { Task { await store.sessions.refresh() } }) { CleanupView(sessions: store.sessions) }
    }

    private func servers(_ servers: [SetupOverview.Server]) -> some View {
        Section {
            if servers.isEmpty { Text("No MCP servers configured.").foregroundStyle(.secondary) }
            ForEach(servers) { server in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    dot(health[server.name])
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name) + Text("  \(scopeName(server))\(server.disabled == true ? ", off" : "")").foregroundStyle(.secondary)
                        Text("\(server.type.uppercased())  \(server.target)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        let keys = server.env.map { "env \($0)" } + server.headers.map { "header \($0)" }
                        if !keys.isEmpty { Text(keys.joined(separator: ", ")).foregroundStyle(.tertiary) }
                    }
                }
                .font(.system(size: 12))
                .accessibilityElement(children: .combine)
            }
        } header: {
            HStack {
                Text("MCP servers")
                Spacer()
                Button(checking ? "Checking…" : "Check connections") { Task { await checkHealth() } }
                    .disabled(checking).controlSize(.small)
                    .help("Runs claude mcp list, which starts each server once.")
            }
        } footer: {
            Text("Values of env and headers are never shown. Connections are checked from your home folder, so project servers elsewhere may not report.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func hooks(_ hooks: [SetupOverview.Hook]) -> some View {
        Section("Hooks") {
            if hooks.isEmpty { Text("No hooks configured.").foregroundStyle(.secondary) }
            ForEach(Array(hooks.enumerated()), id: \.offset) { _, hook in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(hook.event) + Text(hook.matcher.map { "  \($0)" } ?? "").foregroundStyle(.secondary)
                        Spacer()
                        if let mark = hook.sideA {
                            Chip(text: "Side A: \(mark)", tint: .deckOrange)
                        }
                    }
                    Text(hook.command).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                    Text(hook.file).foregroundStyle(.tertiary)
                }
                .font(.system(size: 12))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func names(_ title: String, _ names: [String]) -> some View {
        DisclosureGroup {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in Text(name).font(.system(size: 12)) }
        } label: {
            LabeledContent(title) { Text("\(names.count)").foregroundStyle(.secondary) }
        }
    }

    private func dot(_ status: String?) -> some View {
        let color: Color = switch status {
        case "connected": .green
        case "failed": .red
        case "needs-auth", "pending": .orange
        default: .secondary.opacity(0.4)
        }
        return Circle().fill(color).frame(width: 7, height: 7)
            .accessibilityLabel(status.map { $0 == "needs-auth" ? "Needs sign-in" : $0.capitalized } ?? "Not checked")
    }

    private func scopeName(_ server: SetupOverview.Server) -> String {
        switch server.scope {
        case "project": "project \(server.project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")"
        case "codex": "Codex"
        default: server.scope
        }
    }

    private func load() async {
        guard overview == nil else { return }
        if store.isDemo { overview = .demo; return }
        do { overview = try JSONDecoder().decode(SetupOverview.self, from: try await store.bridgeOutput(["setup", "overview"], timeout: 30, priority: .utility)) }
        catch { failure = error.localizedDescription }
    }

    private func checkHealth() async {
        if store.isDemo { health = SetupOverview.demoHealth; return }
        struct Health: Decodable { let servers: [String: String] }
        checking = true
        defer { checking = false }
        do { health = try JSONDecoder().decode(Health.self, from: try await store.bridgeOutput(["setup", "mcp-health"], timeout: 45)).servers }
        catch { failure = error.localizedDescription }
    }
}
