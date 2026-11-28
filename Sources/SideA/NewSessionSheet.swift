import AppKit
import SideACore
import SideAProtocol
import SwiftUI

/// What the New Session sheet has chosen, apart from the view: which starts it makes, and what each key steps to.
struct NewSessionPlan: Equatable {
    var cwd = ""
    var agents: [AgentProvider] = [.claude]
    var model = ""
    var effort = Effort.auto.rawValue
    var account = ""
    var mode = PermissionMode.default
    var worktree = false
    /// The branch a new worktree is cut from; empty for where the folder is now.
    var base = ""

    /// The modes a new session can start in. One that lifts the agent's checks is asked about before it starts.
    static func modes(_ agent: AgentProvider) -> [PermissionMode] {
        agent == .codex ? [.default, .plan] : [.default, .acceptEdits, .plan, .auto, .bypassPermissions]
    }

    /// The next choice after `current`, wrapping: what a chip's key does.
    static func next<T: Equatable>(after current: T, in choices: [T]) -> T {
        guard let index = choices.firstIndex(of: current) else { return choices.first ?? current }
        return choices[(index + 1) % choices.count]
    }

    /// One start per agent. Several agents each get their own worktree and the settings last used with that agent,
    /// since one model or mode can't be meant for both.
    func starts(prompt: String, hosting: Bool, attachments: [String] = [], remembered: SessionPrefs.Start = .init()) -> [StartHosted] {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return agents.map { agent in
            let several = agents.count > 1
            let saved = remembered.agents[agent.rawValue] ?? .init()
            let model = several ? saved.model : self.model
            let effort = several ? saved.effort : self.effort
            let mode = several ? PermissionMode(rawValue: saved.mode.isEmpty ? "default" : saved.mode) : self.mode
            // A mode that lifts the checks is confirmed each time it is used, so a remembered one never starts unasked.
            let allowed = Self.modes(agent).contains(mode) && mode != .default && !(several && mode.raises)
            return StartHosted(cwd: cwd, agent: agent, model: model.isEmpty ? nil : model,
                               effort: effort.isEmpty || effort == Effort.auto.rawValue ? nil : effort, worktree: hosting && (worktree || several),
                               accountID: hosting && !several && !account.isEmpty ? account : nil, prompt: prompt.isEmpty ? nil : prompt,
                               attachments: hosting ? attachments : [], permissionMode: hosting && allowed ? mode : nil)
        }
    }

    /// The mode whose start has to be confirmed: one that runs tools without asking.
    func raising(hosting: Bool) -> PermissionMode? {
        hosting && agents.count == 1 && mode.raises && Self.modes(agents[0]).contains(mode) ? mode : nil
    }
}

struct NewSessionSheet: View {
    let model: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var plan = NewSessionPlan()
    @State private var projects: [RemoteProject]?
    @State private var options: [AgentOptions] = []
    @State private var terminal = true
    @State private var height = ComposerField.lineHeight
    /// A folder picked with Choose…, which the recent list doesn't hold.
    @State private var chosen: String?
    /// The session last started in the background from this sheet.
    @State private var started: UUID?
    @State private var confirming: (mode: PermissionMode, background: Bool)?

    private static let photos = "new-session"

    private var store: AccountStore { model.store }
    private var hosting: Bool { store.isDemo || (store.hostingWanted && store.hosted.available) }
    private var agent: AgentProvider { plan.agents.first ?? .claude }
    private var several: Bool { plan.agents.count > 1 }
    private var mine: AgentOptions? { options.first { $0.agent == agent } }
    private var picked: ModelOption? { mine?.models.first { $0.id == plan.model } }
    private var project: RemoteProject? { projects?.first { $0.path == plan.cwd } }
    private var accounts: [Account] { store.config.accounts.filter { $0.provider == agent && $0.ready } }
    private var installed: [AgentProvider] { options.filter(\.installed).map(\.agent) }
    private var efforts: [Effort] { picked?.efforts ?? (plan.model.isEmpty && agent == .claude ? RemoteOptions.claudeBase : []) }
    private var git: Bool { project?.gitRoot != nil || FileManager.default.fileExists(atPath: plan.cwd + "/.git") }
    private var folderName: String { plan.cwd.isEmpty ? "" : project?.name ?? URL(fileURLWithPath: plan.cwd).lastPathComponent }
    private var remembered: SessionPrefs.Start { model.desk.prefs.start }
    private var attached: [Upload] { model.attachments[Self.photos] ?? [] }

    var body: some View {
        @Bindable var desk = model.desk
        VStack(alignment: .leading, spacing: 12) {
            Text(folderName.isEmpty ? "New Session" : "What should we build in \(folderName)?").font(.system(size: 15, weight: .semibold)).lineLimit(1)
            VStack(alignment: .leading, spacing: 8) {
                if !attached.isEmpty {
                    Label(attached.count == 1 ? "1 photo" : "\(attached.count) photos", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                        .contextMenu { Button("Remove Photos") { model.attachments[Self.photos] = nil } }
                }
                ComposerField(text: $desk.prompt, height: $height, placeholder: "Describe the task, or leave it empty", onKey: key,
                              onImages: { images in
                                  guard hosting else { return false }
                                  model.attach(images, to: Self.photos)
                                  return true
                              },
                              wantsFocus: desk.composerFocus != desk.composerTaken, onFocus: { desk.composerTaken = desk.composerFocus })
                    .frame(height: max(height, ComposerField.lineHeight * 3))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Ink.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            chips
            HStack(spacing: 10) {
                if hosting { Toggle("Open in \(model.resumeTerminal.title)", isOn: $terminal).toggleStyle(.checkbox).font(.system(size: 12)) }
                Spacer()
                if let started {
                    Button { model.select(started); dismiss() } label: { Label("Started · Open", systemImage: "checkmark.circle") }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Button(started == nil ? "Cancel" : "Done", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if hosting {
                    Button("Start in Background") { start(background: true) }
                        .disabled(plan.cwd.isEmpty)
                        .help("Start it and keep this open for the next one (⌘↩)")
                }
                Button(several ? "Start \(plan.agents.count)" : "Start") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(plan.cwd.isEmpty)
                    .help("Start (↩)")
            }
        }
        .padding(20)
        .frame(width: 600)
        .background { keys }
        .task { await load() }
        .onChange(of: plan.cwd) { _, folder in
            // A branch belongs to the folder it was picked in.
            plan.base = ""
            guard model.desk.seed == nil, !several, let saved = remembered.folders[folder] else { return }
            plan.worktree = saved.worktree && git
            if let used = AgentProvider(rawValue: saved.agent), installed.contains(used), used != agent { choose([used]) }
        }
        .onChange(of: plan.model) { if !efforts.map(\.rawValue).contains(plan.effort) { plan.effort = Effort.auto.rawValue } }
        .confirmationDialog("Start in \(confirming?.mode.title ?? "") mode?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { ask in
            Button("Start", role: .destructive) { begin(background: ask.background) }
        } message: { _ in
            Text("The agent runs commands and edits files in \(folderName) without asking first.")
        }
        .onDisappear { model.attachments[Self.photos] = nil }
    }

    // MARK: Chips

    private var chips: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(projects ?? []) { project in
                    Button(project.branch.map { "\(project.name)  ·  \($0)" } ?? project.name) { plan.cwd = project.path }
                }
                if let chosen, projects?.contains(where: { $0.path == chosen }) != true {
                    Button(URL(fileURLWithPath: chosen).lastPathComponent) { plan.cwd = chosen }
                }
                Divider()
                Button("Choose…", action: chooseFolder)
            } label: { StartChip(symbol: "folder", text: projects == nil && plan.cwd.isEmpty ? "Loading…" : folderName.isEmpty ? "Folder" : folderName) }
                .help("Folder (⌘O chooses any folder)")
            Menu {
                ForEach(installed, id: \.self) { one in Button(Self.name(one)) { choose([one]) } }
                if hosting, git, installed.count > 1 {
                    Divider()
                    Button(installed.map(Self.name).joined(separator: " + ")) { choose(installed) }
                }
            } label: { StartChip(symbol: nil, text: plan.agents.map(Self.name).joined(separator: " + ")) }
                .help(several ? "One session each, in its own worktree, from the one prompt" : "Agent (⇧⌘A)")
            Menu {
                Picker("Model", selection: $plan.model) {
                    Text("Default").tag("")
                    ForEach(mine?.models ?? [], id: \.id) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.inline)
                if !efforts.isEmpty {
                    Picker("Effort", selection: $plan.effort) {
                        ForEach(efforts, id: \.rawValue) { Text($0 == .auto ? "Default" : $0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                }
            } label: { StartChip(symbol: nil, text: several ? "Each agent's last model" : modelText) }
                .disabled(several)
                .help("Model (⇧⌘M) and effort (⇧⌘E)")
            Toggle(isOn: Binding(get: { plan.worktree || several }, set: { plan.worktree = $0 })) {
                StartChip(symbol: "arrow.triangle.branch", text: plan.worktree && !plan.base.isEmpty ? "Worktree from \(plan.base)" : "Worktree", menu: false)
            }
            .toggleStyle(.button).buttonStyle(.plain)
            .disabled(!hosting || !git || several)
            .help(!hosting ? "Needs terminal hosting or Remote" : !git ? "This folder isn't a Git repository" : "In a new worktree (⇧⌘B)")
            .contextMenu { baseItems }
            if plan.worktree, !several, !(project?.branches ?? []).isEmpty {
                Menu { baseItems } label: { StartChip(symbol: nil, text: plan.base.isEmpty ? "from here" : "from \(plan.base)") }.help("The branch the worktree is cut from")
            }
            Menu {
                Picker("Account", selection: $plan.account) {
                    Text("Autopilot's pick").tag("")
                    ForEach(accounts) { account in Text(Self.account(account, usage: store.usage[account.id])).tag(account.id) }
                }
                .pickerStyle(.inline)
            } label: { StartChip(symbol: "person.crop.circle", text: accounts.first { $0.id == plan.account }?.name ?? "Autopilot") }
                .disabled(!hosting || several)
                .help(hosting ? "Account (⇧⌘U)" : "Needs terminal hosting or Remote")
            Menu {
                Picker("Mode", selection: $plan.mode) {
                    ForEach(NewSessionPlan.modes(agent), id: \.self) { Text($0 == .default ? "Ask before acting" : $0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { StartChip(symbol: plan.mode.raises ? "exclamationmark.shield" : "shield", text: plan.mode == .default ? "Ask" : plan.mode.title) }
                .disabled(!hosting || several)
                .help(hosting ? "Permission mode (⇧⌘Y)" : "Needs terminal hosting or Remote")
            Spacer(minLength: 0)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var baseItems: some View {
        Button("From Where It Is Now") { plan.base = "" }
        ForEach(project?.branches ?? [], id: \.self) { branch in Button(branch) { plan.base = branch; plan.worktree = true } }
    }

    private var modelText: String {
        let effort = plan.effort == Effort.auto.rawValue ? nil : Effort(rawValue: plan.effort).title
        return [picked?.title ?? "Default model", effort].compactMap { $0 }.joined(separator: " · ")
    }

    /// The chips' keys, which work while the prompt has the keyboard. Each steps to the next choice.
    private var keys: some View {
        Group {
            Button("Choose Folder", action: chooseFolder).keyboardShortcut("o")
            Button("Next Agent") { if !installed.isEmpty { choose([NewSessionPlan.next(after: agent, in: installed)]) } }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Next Model") { if !several { plan.model = NewSessionPlan.next(after: plan.model, in: [""] + (mine?.models ?? []).map(\.id)) } }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Next Effort") { if !several, !efforts.isEmpty { plan.effort = NewSessionPlan.next(after: plan.effort, in: efforts.map(\.rawValue)) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Worktree") { if hosting, git, !several { plan.worktree.toggle() } }.keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Next Account") { if hosting, !several { plan.account = NewSessionPlan.next(after: plan.account, in: [""] + accounts.map(\.id)) } }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Next Mode") { if hosting, !several { plan.mode = NewSessionPlan.next(after: plan.mode, in: NewSessionPlan.modes(agent)) } }
                .keyboardShortcut("y", modifiers: [.command, .shift])
        }
        .opacity(0).accessibilityHidden(true)
    }

    private func key(_ key: ComposerField.Key) -> Bool {
        switch key {
        case .send: start()
        case .other: if hosting { start(background: true) }
        default: return false
        }
        return true
    }

    static func name(_ agent: AgentProvider) -> String { agent == .codex ? "Codex" : "Claude" }

    /// "Work · 5h 42%", or just the name before its usage is read.
    static func account(_ account: Account, usage: AccountUsage?) -> String {
        guard let window = usage?.fiveHour ?? usage?.windows.first else { return account.name }
        return "\(account.name)  ·  \(window.label) \(window.text(at: Date().timeIntervalSince1970))"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder to start a session in"
        if !plan.cwd.isEmpty { panel.directoryURL = URL(fileURLWithPath: plan.cwd) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chosen = url.path
        plan.cwd = url.path
        model.desk.composerFocus += 1
    }

    // MARK: Loading and remembering

    /// The folders and the agents' options each fill in as they arrive: neither list waits for the other.
    private func load() async {
        terminal = remembered.terminal
        model.desk.composerFocus += 1
        if let seed = model.desk.seed {
            plan.cwd = seed.cwd
            plan.agents = [seed.agent]
            model.desk.prompt = seed.prompt ?? ""
        } else if let folder = model.desk.startFolder {
            plan.cwd = folder
            chosen = folder
        }
        model.desk.startFolder = nil
        async let folders: Void = loadFolders()
        async let agents: Void = loadAgents()
        _ = await (folders, agents)
    }

    private func loadFolders() async {
        let found = await RemoteProjects.list(store.remote)
        projects = found
        if plan.cwd.isEmpty { plan.cwd = SessionPrefs.Start.folder(remembered, open: model.openSession?.cwd, among: found.map(\.path)) }
        if chosen == nil, !plan.cwd.isEmpty, !found.contains(where: { $0.path == plan.cwd }) { chosen = plan.cwd }
    }

    private func loadAgents() async {
        options = await RemoteOptions.agents(store.remote) ?? []
        if let seed = model.desk.seed {
            model.desk.seed = nil
            return restore(seed)
        }
        let wanted = remembered.folders[plan.cwd].flatMap { AgentProvider(rawValue: $0.agent) } ?? AgentProvider(rawValue: remembered.agent) ?? agent
        choose([installed.contains(wanted) ? wanted : installed.first ?? wanted])
    }

    /// A failed start being edited comes back as it was asked for, not as the last successful one.
    private func restore(_ seed: StartHosted) {
        plan.model = options.first { $0.agent == seed.agent }?.models.contains { $0.id == seed.model } == true ? seed.model ?? "" : ""
        plan.effort = seed.effort ?? Effort.auto.rawValue
        plan.account = seed.accountID ?? ""
        plan.worktree = seed.worktree
        plan.mode = seed.permissionMode ?? .default
    }

    /// Choosing an agent brings back the model, effort, account and mode last used with it, where they still exist.
    private func choose(_ agents: [AgentProvider]) {
        plan.agents = agents
        guard let agent = agents.first, agents.count == 1 else { return }
        let saved = remembered.agents[agent.rawValue] ?? .init()
        plan.model = options.first { $0.agent == agent }?.models.contains { $0.id == saved.model } == true ? saved.model : ""
        plan.effort = saved.effort.isEmpty ? Effort.auto.rawValue : saved.effort
        plan.account = store.config.accounts.contains { $0.id == saved.account && $0.provider == agent && $0.ready } ? saved.account : ""
        let mode = PermissionMode(rawValue: saved.mode)
        // A mode that lifts the checks is chosen each time, never remembered into.
        plan.mode = NewSessionPlan.modes(agent).contains(mode) && !mode.raises ? mode : .default
    }

    // MARK: Starting

    private func start(background: Bool = false) {
        guard !plan.cwd.isEmpty else { return }
        if let mode = plan.raising(hosting: hosting) { return confirming = (mode, background) }
        begin(background: background)
    }

    /// The sheet goes at once: the row and the window show each session starting, and say so if it can't.
    private func begin(background: Bool) {
        let photos = attached
        let starts = plan.starts(prompt: model.desk.prompt, hosting: hosting, attachments: photos.map(\.id), remembered: remembered)
        var saved = remembered
        for start in starts where !several { saved.record(start) }
        saved.terminal = terminal
        model.desk.prefs.start = saved
        model.desk.prompt = ""
        model.attachments[Self.photos] = nil
        for (index, start) in starts.enumerated() {
            // Only the first of several opens a tab and takes the window.
            model.launch(start, terminal: terminal && !background && index == 0, select: !background && index == 0, images: photos.map(\.path),
                         base: plan.base.isEmpty ? nil : plan.base)
        }
        if background { started = model.desk.launches.first?.id } else { dismiss() }
    }
}

/// A choice in the New Session sheet's row: what is chosen now, opening to the others.
struct StartChip: View {
    let symbol: String?
    let text: String
    var menu = true
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5)) }
            Text(text).font(.system(size: 12)).lineLimit(1)
            if menu { Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 8).frame(height: 24)
        .background(Ink.field, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.line))
        .contentShape(Capsule())
    }
}
