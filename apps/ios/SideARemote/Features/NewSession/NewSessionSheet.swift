import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftUI

struct NewSessionSheet: View {
    let onStarted: (HostedSession, AppModel) -> Void
    @Environment(AppRoot.self) private var root
    @Environment(KeyRequests.self) private var keys: KeyRequests?
    @Environment(AppModel.self) private var shown
    @Environment(\.dismiss) private var dismiss
    private var form: NewSessionForm { root.newSession }
    private var macID: String? { get { form.macID } nonmutating set { form.macID = newValue } }
    private var prompt: String { get { form.prompt } nonmutating set { form.prompt = newValue } }
    private var project: RemoteProject? { get { form.project } nonmutating set { form.project = newValue } }
    private var agent: AgentProvider { get { form.agent } nonmutating set { form.agent = newValue } }
    private var modelID: String? { get { form.modelID } nonmutating set { form.modelID = newValue } }
    private var effort: Effort? { get { form.effort } nonmutating set { form.effort = newValue } }
    private var worktree: Bool { get { form.worktree } nonmutating set { form.worktree = newValue } }
    private var accountID: String? { get { form.accountID } nonmutating set { form.accountID = newValue } }
    private var key: String { get { form.key } nonmutating set { form.key = newValue } }
    private var draft: String { form.draft }
    @AppStorage(PrefKey.openOnMac) private var openOnMac = true
    @State private var error: String?
    @State private var loadError: String?
    @State private var starting = false
    @State private var waitingForMac = false
    @State private var startTask: Task<Void, Never>?
    @State private var loading = true
    @State private var picking = false
    @State private var discarding = false
    @State private var choosingModel = false
    @State private var started = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowIsRegular) private var wide
    @State private var contentHeight: CGFloat = 0
    @State private var barHeight: CGFloat = 0
    @State private var focused = false
    @State private var promptSelection = NSRange(location: 0, length: 0)
    @State private var attach = AttachSurface()
    @State private var held: ComposerAttachments?
    @State private var dictation = Dictation()

    private var hosts: [AppModel] { root.macs.filter { $0.tools.can(.hosted) } }
    private var asksMac: Bool { hosts.count > 1 }
    private var model: AppModel {
        Self.target(picked: macID, shown: root.shown, last: ListPrefsStore.lastHost(), hosts: hosts.map(\.macID)).flatMap(root.model(for:)) ?? shown
    }
    /// Where a new session starts: the computer picked in the sheet, else the one the list is showing, else the one the
    /// last session was started on, else the first that can host. Never one that can't host while another can.
    static func target(picked: String?, shown: String?, last: String?, hosts: [String]) -> String? {
        if let picked { return picked }
        return [shown, last].compactMap(\.self).first(where: hosts.contains) ?? hosts.first
    }
    private var tools: MacTools { model.tools }
    private var canStart: Bool {
        project != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !starting && !uploading && !dictation.isBusy
    }
    private var attachments: ComposerAttachments { tools.attachments }
    private var canAttach: Bool { tools.can(.uploads) }
    private var uploading: Bool { attachments.isUploading(draft) }
    private var hasDraft: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.items(draft).isEmpty || dictation.holdsRecording
    }
    private var room: Int { attach.room(draft, tools: tools) }
    private var models: [ModelOption] { tools.models(for: agent) }
    private var chosenModel: ModelOption? { models.first { $0.id == modelID } }
    private var accounts: [RemoteAccount] { model.accounts.accounts.filter { $0.provider == agent && $0.ready } }
    private var pinned: RemoteAccount? { accounts.first { $0.id == accountID } }
    /// The login a session with no account picked runs on: the one in use on that computer.
    private var inUse: RemoteAccount? { accounts.first(where: \.active) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    heading
                    if !folders.isEmpty { folderChips }
                    agentChips
                    ComposerField(text: Bindable(form).prompt, selection: $promptSelection, isFocused: $focused, placeholder: "What should it do?",
                                  label: "Prompt", minLines: 4, maxLines: nil, insets: .zero, drawer: attach.drawer, paste: attach.target)
                        .padding(Space.s)
                        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 16, style: .continuous))
                    PromptDictation(dictation: dictation, text: Bindable(form).prompt, selection: $promptSelection, focused: $focused, model: model,
                                    project: project?.name, shelf: draft)
                }
                .padding(Space.m)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollDismissesKeyboard(.never)
            .safeAreaBar(edge: .bottom) { chipBar }
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .overlay {
                if loading && tools.projects.isEmpty {
                    ProgressView()
                } else if tools.projects.isEmpty, let loadError {
                    ContentUnavailableView {
                        Label("Can't Load Folders", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try Again") {
                            loading = true
                            Task { await load() }
                        }
                        .buttonStyle(.glass)
                    }
                } else if tools.projects.isEmpty {
                    ContentUnavailableView("No Folders Yet", systemImage: "folder",
                                           description: Text("Folders where you've used Claude or Codex on \(model.mac.name) show here."))
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { hasDraft ? (discarding = true) : leave() }
                        .keyboardShortcut(attach.drawer.isOpen ? nil : .cancelAction)
                        .confirmationDialog("Discard this session?", isPresented: $discarding) {
                            Button("Discard", role: .destructive) { leave() }
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
            .navigationDestination(isPresented: $picking) { ProjectPicker(selection: Bindable(form).project).environment(model) }
        }
        .frame(idealHeight: wide ? 56 + max(contentHeight, 300) + barHeight : nil)
        .interactiveDismissDisabled(starting || dictation.isBusy || attach.strip.holdsTouch)
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .attachments(attach, key: draft, tools: tools)
        .onChange(of: ObjectIdentifier(tools.attachments), initial: true) {
            if let held, held !== tools.attachments { held.rehome(draft, to: tools.attachments) }
            held = tools.attachments
        }
        .sensoryFeedback(.success, trigger: started)
        .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        .task(id: model.macID) { await load() }
        .onChange(of: model.macID) { project = nil; loading = true }
        .onChange(of: agent) { keepOffered() }
        .onChange(of: modelID) { keepOffered() }
        .onChange(of: prompt) { newDraftStarted() }
        .onAppear { focused = true }
        #if DEBUG
        .task { await debugLaunch() }
        #endif
    }

    #if DEBUG
    private func debugLaunch() async {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } }
        guard arguments.contains("--new-session") else { return }
        try? await Task.sleep(for: .milliseconds(1200))
        if let text = value("--prompt-text") { prompt = text }
        if arguments.contains("--attach-failed") {
            let id = attachments.reserve(preview: Self.debugPicture(0), in: draft, refetch: { nil })
            if let id { attachments.fail(id, "The photo couldn't be loaded.", in: draft) }
        }
        for n in 0..<(value("--attach").flatMap(Int.init) ?? 0) {
            attachments.add(Self.debugPicture(n).jpegData(compressionQuality: 0.8)!, to: draft)
        }
        if arguments.contains("--pick-folder") { project = tools.projects.first }
        if arguments.contains("--start") {
            try? await Task.sleep(for: .milliseconds(600))
            start()
        }
        if let mode = value("--drawer") {
            try? await Task.sleep(for: .milliseconds(900))
            attach.open(key: draft, tools: tools, reduceMotion: reduceMotion)
            if mode == "large" { try? await Task.sleep(for: .milliseconds(900)); attach.drawer.toggleDetent() }
        }
    }

    private static func debugPicture(_ n: Int) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { context in
            UIColor(hue: CGFloat(n) / 10, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            ("\(n + 1)" as NSString).draw(at: CGPoint(x: 70, y: 50), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 90), .foregroundColor: UIColor.white])
        }
    }
    #endif

    private var recent: [RemoteProject] { tools.recentProjects }

    /// The chosen folder leads even when it isn't among the recent ones.
    private var folders: [RemoteProject] {
        guard let project, !recent.contains(where: { $0.id == project.id }) else { return recent }
        return [project] + recent
    }

    private var heading: some View {
        Group {
            if let project {
                Text("What should we build in \(Text(project.name).foregroundStyle(.tint))?")
            } else {
                Text("What should we build?")
            }
        }
        .font(.title2.bold())
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .animation(Motion.smooth(reduceMotion), value: project?.id)
    }

    private var folderChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.xs) {
                ForEach(folders) { folder in
                    Button { project = folder } label: {
                        PickChip(symbol: "folder", text: folder.name, selected: folder.id == project?.id)
                    }
                    .accessibilityLabel("Folder, \(folder.name)")
                    .accessibilityAddTraits(folder.id == project?.id ? .isSelected : [])
                }
                Button { picking = true } label: { PickChip(symbol: "ellipsis", text: "More", selected: false) }
                    .accessibilityLabel("Choose another folder")
            }
            .padding(.horizontal, Space.m)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -Space.m)
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: project?.id)
    }

    private var agentChips: some View {
        HStack(spacing: Space.xs) {
            ForEach([AgentProvider.claude, .codex], id: \.self) { provider in
                let installed = tools.agent(provider)?.installed ?? (tools.options == nil)
                Button { agent = provider } label: {
                    PickChip(symbol: provider.symbol, text: provider.title, selected: provider == agent)
                }
                .disabled(!installed)
                .opacity(installed ? 1 : 0.4)
                .accessibilityLabel(installed ? provider.title : "\(provider.title), not installed")
                .accessibilityAddTraits(provider == agent ? .isSelected : [])
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: agent)
    }

    private var chipBar: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            AttachmentTray(session: draft)
                .environment(model)
                .padding(.horizontal, Space.m)
            if attach.strip.isShown {
                RecentStripView(strip: attach.strip, window: attach.drawer.window)
                    .padding(.horizontal, Space.m)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.destructive)
                    .padding(.horizontal, Space.m)
                    .transition(.opacity)
            } else if waitingForMac {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Label("Starts when connected", systemImage: "tray.and.arrow.up").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Stop Waiting") { startTask?.cancel() }
                        .fontWeight(.semibold)
                        .buttonStyle(.borderless)
                        .hitArea(vertical: 12)
                }
                .font(.footnote)
                .padding(.horizontal, Space.m)
                .transition(.opacity)
            }
            Group {
                if wide {
                    GlassEffectContainer(spacing: Space.xs) {
                        ChipFlow(spacing: Space.xs) {
                            if canAttach { attachButton }
                            chipItems
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Space.m)
                } else {
                    HStack(spacing: Space.xs) {
                        if canAttach { attachButton.padding(.leading, Space.m) }
                        chips
                    }
                }
            }
        }
        .padding(.vertical, Space.xs)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
        .animation(Motion.smooth(reduceMotion), value: error)
        .animation(Motion.smooth(reduceMotion), value: waitingForMac)
        .animation(Motion.smooth(reduceMotion), value: attachments.items(draft).map(\.id))
        .animation(Motion.smooth(reduceMotion), value: attach.strip.isShown)
    }

    private var attachButton: some View {
        AttachButton(surface: attach, key: draft, tools: tools, diameter: 44, glyph: 17, label: "Attach photos")
        .attachPopover(attach)
        .disabled(room == 0)
        .needsMac()
        .environment(model)
    }

    @ViewBuilder private var chipItems: some View {
        if asksMac { macChip }
        if !models.isEmpty { modelChip }
        if project?.gitRoot != nil { worktreeChip }
        if accounts.count > 1 { accountChip }
        if tools.can(.hostedShow) { macTabChip }
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: Space.xs) {
                    HStack(spacing: Space.xs) { chipItems }
                    .padding(.leading, canAttach ? 0 : Space.m)
                    .padding(.trailing, Space.m)
                }
            }
            .scrollIndicators(.hidden)
            .buttonStyle(.plain)
        }
    }

    private var macChip: some View {
        Menu {
            Picker(hosts.map(\.mac.kind).shared.titleNoun, selection: Binding { Optional(model.macID) } set: { macID = $0 }) {
                ForEach(hosts, id: \.macID) { mac in
                    Label(mac.mac.name, systemImage: mac.mac.symbol).tag(Optional(mac.macID))
                }
            }
        } label: {
            ChipLabel(symbol: model.mac.symbol, text: model.mac.name)
        }
        .accessibilityLabel("\(model.mac.kind.titleNoun), \(model.mac.name)")
    }

    private var modelChip: some View {
        Button { choosingModel = true } label: {
            ChipLabel(symbol: nil, text: ModelOption.chipText(chosenModel, effort: effort))
        }
        .accessibilityLabel("Model, \(ModelOption.chipText(chosenModel, effort: effort))")
        .sheet(isPresented: $choosingModel) {
            ModelEffortSheet(models: models, offersDefault: true, modelID: Bindable(form).modelID, effort: Bindable(form).effort)
        }
    }

    private var worktreeChip: some View {
        Menu {
            Picker("Worktree", selection: Bindable(form).worktree) {
                Text("In the folder").tag(false)
                Text("New worktree").tag(true)
            }
        } label: {
            ChipLabel(symbol: "arrow.triangle.branch", text: worktree ? "New worktree" : "No worktree")
        }
        .accessibilityLabel(worktree ? "In a new worktree" : "In the folder, no worktree")
    }

    private var macTabChip: some View {
        Menu {
            Picker("\(model.mac.kind.titleNoun) Tab", selection: $openOnMac) {
                Text("Also open a tab on \(model.mac.name)").tag(true)
                Text("Only on \(ThisDevice.kind)").tag(false)
            }
        } label: {
            ChipLabel(symbol: openOnMac ? "macwindow" : ThisDevice.symbol, text: openOnMac ? "Tab on \(model.mac.name)" : "\(ThisDevice.kind) only")
        }
        .accessibilityLabel(openOnMac ? "Also opens a tab on \(model.mac.name)" : "Runs without a tab on \(model.mac.name)")
    }

    private var accountChip: some View {
        Menu {
            Picker("Account", selection: Bindable(form).accountID) {
                Text(inUse.map { "Auto · \($0.name)" } ?? "Auto").tag(String?.none)
                ForEach(accounts) { account in
                    let tightest = model.accounts.tightest(account).map { " · " + $0.text(at: Date.now.timeIntervalSince1970) } ?? ""
                    Text(account.name + tightest).tag(Optional(account.id))
                }
            }
        } label: {
            ChipLabel(symbol: "person.crop.circle", text: (pinned ?? inUse)?.name ?? "Auto")
        }
        .accessibilityLabel("Account, \(pinned?.name ?? inUse.map { "automatic, \($0.name)" } ?? "automatic")")
    }

    private func load() async {
        if tools.options != nil { seed() }
        async let options: Void = tools.loadOptions()
        loadError = nil
        do { try await tools.loadProjects() } catch { loadError = MacTools.message(error) }
        await options
        loading = false
        seed()
        if project == nil { project = recent.first }
        if tools.agent(agent)?.installed == false, let other = AgentProvider.allCases.first(where: { tools.agent($0)?.installed == true }) {
            agent = other
        }
    }

    private func seed() {
        guard form.seeded != model.macID else { return }
        // Another Mac has its own models and accounts. Cleared here, not in onChange(of: macID), which can run after this.
        if form.seeded != nil { modelID = nil; effort = nil; accountID = nil; worktree = false }
        form.seeded = model.macID
        guard let last = ListPrefsStore.newSession(mac: model.macID) else { return }
        if let remembered = last.agent, tools.agent(remembered)?.installed != false { agent = remembered }
        if let id = last.modelID, let option = tools.models(for: agent).first(where: { $0.id == id }) {
            modelID = id
            if let remembered = last.effort, option.efforts.contains(remembered) { effort = remembered }
        }
        worktree = last.worktree
    }

    private func keepOffered() {
        if let modelID, !models.contains(where: { $0.id == modelID }) { self.modelID = nil }
        if let effort, chosenModel?.efforts.contains(effort) != true { self.effort = nil }
        if let accountID, !accounts.contains(where: { $0.id == accountID }) { self.accountID = nil }
    }

    private func leave() {
        startTask?.cancel()
        // Thrown away, not finished: closing the sheet would otherwise send what's being said.
        dictation.cancel(refocus: false)
        let form = root.newSession, photos = draft, tray = attachments, app = root, requests = keys, undoable = hasDraft
        app.newSession = NewSessionForm()
        dismiss()
        guard undoable else { return tray.discard(photos) }
        Self.discardNotice = Pill.undoable("Draft discarded", expired: { tray.discard(photos) }) {
            Self.discardNotice = nil
            let newer = app.newSession
            guard newer.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, tray.items(newer.draft).isEmpty else {
                return tray.discard(photos)
            }
            app.newSession = form
            requests?.newSession += 1
        }
    }

    @MainActor private static var discardNotice: Pill.Item.ID?

    private func newDraftStarted() {
        guard let notice = Self.discardNotice, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Self.discardNotice = nil
        Pill.end(notice)
    }

    private func start() {
        guard let project else { return }
        let photos: [String]
        switch attachments.gate(draft) {
        case .uploading: return
        case .failed:
            error = "A photo didn't upload. Retry it or remove it."
            return
        case .ready(let ids): photos = ids
        }
        let request = StartHosted(cwd: project.path, agent: agent, model: modelID, effort: effort?.rawValue, worktree: worktree && project.gitRoot != nil,
                                  accountID: accountID, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                  attachments: photos, openOnMac: tools.can(.hostedShow) && openOnMac ? true : nil)
        let choices = NewSessionPrefs(agent: agent, modelID: modelID, effort: effort, accountID: accountID, worktree: worktree)
        // The computer as chosen now: picking another while this waits must not move where it lands.
        let model = model, tools = tools, attachments = attachments
        starting = true
        error = nil
        let tapped = Date.now
        startTask = Task {
            defer { starting = false; waitingForMac = false }
            do {
                let hosted = try await tools.start(request, key: key) { waitingForMac = true }
                model.transcripts.started(hosted.name, prompt: request.prompt ?? "", at: tapped)
                _ = attachments.take(draft, for: model.transcripts.firstPrompts[hosted.name]?.id)
                started += 1
                dictation.cancel(refocus: false)
                ListPrefsStore.setNewSession(choices, mac: model.macID)
                ListPrefsStore.setLastHost(model.macID)
                root.newSession = NewSessionForm()
                dismiss()
                onStarted(hosted, model)
            } catch let failure as RemoteFailure where failure.error.code == .outcomeUnknown {
                // The first try may have started it; a new key is a new session, so only the user decides. The prompt
                // and the photos stay where they are.
                key = UUID().uuidString.lowercased()
                error = "This may or may not have reached \(model.mac.name). Check Sessions before starting again."
            } catch let failure as RemoteFailure where failure.error.details?["reason"] == "unknown_upload" {
                attachments.reupload(draft)
                error = "A photo went up again. Start once it's done."
            } catch {
                if !Task.isCancelled { self.error = MacTools.message(error) }
            }
        }
    }
}

struct PickChip: View {
    let symbol: String?
    let text: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, Space.s)
        .frame(minHeight: 36)
        .foregroundStyle(selected ? Color(.systemBackground) : Color(.label))
        .background(selected ? Color(.label) : Color(.tertiarySystemFill), in: .capsule)
        .contentShape(.capsule)
        .hitArea(vertical: 4)
        .hoverEffect(.highlight)
    }
}

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
        .foregroundStyle(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .glassEffect(.regular.interactive(), in: .capsule)
        .contentShape(.capsule)
        .hoverEffect(.highlight)
    }
}

private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

@Observable
final class NewSessionForm {
    nonisolated deinit {}

    var macID: String?
    var prompt = ""
    var project: RemoteProject?
    var agent: AgentProvider = .claude
    var modelID: String?
    var effort: Effort?
    var worktree = false
    var accountID: String?
    var seeded: String?
    var key = UUID().uuidString.lowercased()
    let draft = "new-session-" + UUID().uuidString.lowercased()
}
