import SideAProtocol
import SideARemoteKit
import SwiftUI

/// New Session (section 4.8): a prompt that fills the sheet, recent folders under it until the user
/// types, and chips riding the keyboard for folder, agent, model and effort, worktree and account.
/// Start posts `/v1/hosted` under one key per sheet, so a second tap can't make a second session.
/// With several Macs, the first chip asks which one, unless Sessions already shows only one.
struct NewSessionSheet: View {
    let onStarted: (HostedSession, AppModel) -> Void
    @Environment(AppRoot.self) private var root
    @Environment(AppModel.self) private var shown
    /// The Mac picked in the chip; nil until picked when several could start it.
    @State private var macID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var project: RemoteProject?
    @State private var agent: AgentProvider = .claude
    @State private var modelID: String?
    @State private var effort: Effort?
    @State private var worktree = false
    @State private var accountID: String?
    @State private var error: String?
    @State private var starting = false
    @State private var loading = true
    @State private var picking = false
    @State private var discarding = false
    @State private var started = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var key = UUID().uuidString.lowercased()
    @FocusState private var focused: Bool

    /// The Macs that can start a session here.
    private var hosts: [AppModel] { root.macs.filter { $0.tools.can(.hosted) } }
    private var asksMac: Bool { hosts.count > 1 }
    private var model: AppModel {
        macID.flatMap(root.model(for:)) ?? (asksMac && root.shown == nil ? hosts.first : nil) ?? shown
    }
    private var tools: MacTools { model.tools }
    private var macPicked: Bool { macID != nil || !asksMac || root.shown != nil }
    private var canStart: Bool {
        project != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !starting && macPicked
    }
    private var models: [ModelOption] { tools.models(for: agent) }
    private var chosenModel: ModelOption? { models.first { $0.id == modelID } }
    private var accounts: [RemoteAccount] { model.accounts.accounts.filter { $0.provider == agent } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    TextField("What should it do?", text: $prompt, axis: .vertical)
                        .font(.body)
                        .lineLimit(6...)
                        .focused($focused)
                        .accessibilityLabel("Prompt")
                    if prompt.isEmpty, project == nil, !recent.isEmpty, macPicked {
                        suggestions
                    }
                }
                .padding(Space.m)
            }
            .scrollDismissesKeyboard(.never)
            .safeAreaBar(edge: .bottom) { chipBar }
            // Recent rows scroll under the chips at large text sizes: cut them off cleanly.
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .overlay {
                if !macPicked {
                    EmptyView()
                } else if loading && tools.projects.isEmpty {
                    ProgressView()
                } else if tools.projects.isEmpty {
                    ContentUnavailableView("No Folders Yet", systemImage: "folder",
                                           description: Text("Folders where you've used Claude or Codex on \(model.mac.name) show here."))
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { prompt.isEmpty ? dismiss() : (discarding = true) }
                        .confirmationDialog("Discard this session?", isPresented: $discarding) {
                            Button("Discard", role: .destructive) { dismiss() }
                        }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if starting {
                        ProgressView()
                    } else {
                        Button("Start") { start() }
                            .buttonStyle(.glassProminent)
                            .disabled(!canStart)
                    }
                }
            }
            .sheet(isPresented: $picking) { ProjectPicker(selection: $project).environment(model) }
        }
        .interactiveDismissDisabled(!prompt.isEmpty || starting)
        .sensoryFeedback(.success, trigger: started)
        .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        .task(id: model.macID) { await load() }
        // Another Mac has its own folders, models and accounts.
        .onChange(of: macID) { project = nil; modelID = nil; effort = nil; accountID = nil; loading = true }
        .onChange(of: agent) { modelID = nil; effort = nil; accountID = nil }
        .onChange(of: modelID) { effort = nil }
        .onChange(of: project) { if project?.gitRoot == nil { worktree = false } }
        .onAppear { focused = true }
    }

    private var recent: [RemoteProject] { Array(tools.projects.sorted { ($0.lastUsedAt ?? 0) > ($1.lastUsedAt ?? 0) }.prefix(5)) }

    /// Linear's suggestions: one tap sets the folder.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Recent")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(recent) { folder in
                Button { project = folder } label: { ProjectRow(project: folder) }
                    .buttonStyle(.plain)
            }
        }
    }

    // MARK: Chips

    private var chipBar: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, Space.m)
                    .transition(.opacity)
            }
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: Space.xs) {
                    HStack(spacing: Space.xs) {
                        if asksMac { macChip }
                        Button { picking = true } label: {
                            ChipLabel(symbol: "folder", text: project?.name ?? "Folder",
                                      prominent: project == nil && macPicked)
                        }
                        .disabled(!macPicked)
                        .accessibilityLabel(project.map { "Folder, \($0.name)" } ?? "Choose a folder")
                        agentChip
                        if !models.isEmpty { modelChip }
                        if project?.gitRoot != nil { worktreeChip }
                        if accounts.count > 1 { accountChip }
                    }
                    .padding(.horizontal, Space.m)
                }
            }
            .scrollIndicators(.hidden)
            .buttonStyle(.plain)
        }
        .padding(.vertical, Space.xs)
        .animation(Motion.smooth(reduceMotion), value: error)
    }

    private var macChip: some View {
        Menu {
            Picker("Mac", selection: Binding { macID ?? (root.shown != nil ? model.macID : nil) } set: { macID = $0 }) {
                ForEach(hosts, id: \.macID) { mac in
                    Label(mac.mac.name, systemImage: "laptopcomputer").tag(Optional(mac.macID))
                }
            }
        } label: {
            ChipLabel(symbol: "laptopcomputer", text: macPicked ? model.mac.name : "Mac", prominent: !macPicked)
        }
        .accessibilityLabel(macPicked ? "Mac, \(model.mac.name)" : "Choose a Mac")
    }

    private var agentChip: some View {
        Menu {
            Picker("Agent", selection: $agent) {
                ForEach([AgentProvider.claude, .codex], id: \.self) { provider in
                    let installed = tools.agent(provider)?.installed ?? (tools.options == nil)
                    Label(provider.title + (installed ? "" : " · Not installed"), systemImage: provider.symbol)
                        .tag(provider)
                        .selectionDisabled(!installed)
                }
            }
        } label: {
            ChipLabel(symbol: agent.symbol, text: agent.title)
        }
        .accessibilityLabel("Agent, \(agent.title)")
    }

    private var modelChip: some View {
        Menu {
            Picker("Model", selection: $modelID) {
                Text("Default").tag(String?.none)
                ForEach(models, id: \.id) { Text($0.title).tag(Optional($0.id)) }
            }
            if let chosenModel, !chosenModel.efforts.isEmpty {
                Picker("Effort", systemImage: "gauge.with.dots.needle.50percent", selection: $effort) {
                    ForEach(chosenModel.efforts, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.menu)
            }
        } label: {
            let effortText = (effort ?? chosenModel?.defaultEffort).flatMap { $0 == .auto ? nil : $0.title }
            ChipLabel(symbol: nil, text: [chosenModel?.title ?? "Default model", effortText].compactMap { $0 }.joined(separator: " · "))
        }
        .accessibilityLabel("Model, \(chosenModel?.title ?? "default")")
    }

    private var worktreeChip: some View {
        Menu {
            Picker("Worktree", selection: $worktree) {
                Text("In the folder").tag(false)
                Text("New worktree").tag(true)
            }
        } label: {
            ChipLabel(symbol: "arrow.triangle.branch", text: worktree ? "New worktree" : "No worktree")
        }
        .accessibilityLabel(worktree ? "In a new worktree" : "In the folder, no worktree")
    }

    private var accountChip: some View {
        Menu {
            Picker("Account", selection: $accountID) {
                Text("Auto").tag(String?.none)
                ForEach(accounts) { account in
                    let tightest = model.accounts.tightest(account).map { " · " + $0.text(at: Date.now.timeIntervalSince1970) } ?? ""
                    Text(account.name + tightest).tag(Optional(account.id))
                }
            }
        } label: {
            ChipLabel(symbol: "person.crop.circle", text: accounts.first { $0.id == accountID }?.name ?? "Auto")
        }
        .accessibilityLabel("Account, \(accounts.first { $0.id == accountID }?.name ?? "automatic")")
    }

    // MARK: Actions

    private func load() async {
        async let options: Void = tools.loadOptions()
        do { try await tools.loadProjects() } catch { self.error = MacTools.message(error) }
        await options
        loading = false
        if project == nil, tools.projects.count == 1 { project = tools.projects.first }
        if tools.agent(.claude)?.installed == false, tools.agent(.codex)?.installed == true { agent = .codex }
    }

    private func start() {
        guard let project else { return }
        let request = StartHosted(cwd: project.path, agent: agent, model: modelID, effort: effort?.rawValue, worktree: worktree,
                                  accountID: accountID, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        starting = true
        error = nil
        Task {
            defer { starting = false }
            do {
                let hosted = try await tools.start(request, key: key)
                started += 1
                dismiss()
                onStarted(hosted, model)
            } catch let failure as RemoteFailure where failure.error.code == .outcomeUnknown {
                // The first try may have started it; a new key is a new session, so only the user decides.
                key = UUID().uuidString.lowercased()
                error = "This may or may not have reached \(model.mac.name). Check Sessions before starting again."
            } catch {
                self.error = MacTools.message(error)
            }
        }
    }
}

/// A glass capsule in the chip bar.
struct ChipLabel: View {
    let symbol: String?
    let text: String
    var prominent = false

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
        // The accent, as amber is kept for what needs you.
        .foregroundStyle(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .glassEffect(.regular.interactive(), in: .capsule)
        .contentShape(.capsule)
    }
}
