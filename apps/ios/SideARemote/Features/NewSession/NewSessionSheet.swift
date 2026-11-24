import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftUI

/// New Session: a prompt that fills the sheet, recent folders under it until the user
/// types, and chips riding the keyboard for folder, agent, model and effort, worktree and account.
/// Start posts `/v1/hosted` under one key per sheet, so a second tap can't make a second session.
/// With several Macs, the first chip asks which one, unless Sessions already shows only one.
/// A + beside the chips attaches photos through the same drawer and tray as a session's composer. They upload to the
/// Mac as they are picked, under a key of the sheet's own (uploads belong to the phone, not to a session), and Start
/// names them in the same request as the prompt, so the Mac either starts the session with them or starts nothing.
struct NewSessionSheet: View {
    let onStarted: (HostedSession, AppModel) -> Void
    @Environment(AppRoot.self) private var root
    @Environment(KeyRequests.self) private var keys: KeyRequests?
    @Environment(AppModel.self) private var shown
    @Environment(\.dismiss) private var dismiss
    /// The draft, held by the app until it starts or is discarded (`NewSessionForm`).
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
    /// A terminal tab on the Mac attached to it as well, so it's in the Mac's tabs too. Remembered across sheets.
    @AppStorage("newSession.openOnMac") private var openOnMac = true
    @State private var error: String?
    /// The folders wouldn't load: shown in place of the list, with Try Again, not in the chip bar.
    @State private var loadError: String?
    @State private var starting = false
    /// Start missed the Mac and asks again under the same key until it's back or the signature runs out.
    @State private var waitingForMac = false
    @State private var startTask: Task<Void, Never>?
    @State private var loading = true
    @State private var picking = false
    @State private var discarding = false
    @State private var choosingModel = false
    @State private var started = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowIsRegular) private var wide
    /// The prompt and recents' height, so a fitted iPad sheet is as tall as they are.
    @State private var contentHeight: CGFloat = 0
    @State private var barHeight: CGFloat = 0
    @State private var focused = false
    @State private var promptSelection = NSRange(location: 0, length: 0)
    @State private var attach = AttachSurface()
    /// The tray the photos are in, so a different Mac can have them sent to it.
    @State private var held: ComposerAttachments?
    @State private var dictation = Dictation()

    /// The Macs that can start a session here.
    private var hosts: [AppModel] { root.macs.filter { $0.tools.can(.hosted) } }
    private var asksMac: Bool { hosts.count > 1 }
    private var model: AppModel {
        macID.flatMap(root.model(for:)) ?? (asksMac && root.shown == nil ? hosts.first : nil) ?? shown
    }
    private var tools: MacTools { model.tools }
    private var macPicked: Bool { macID != nil || !asksMac || root.shown != nil }
    private var canStart: Bool {
        project != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !starting && macPicked && !uploading && !dictation.isBusy
    }
    private var attachments: ComposerAttachments { tools.attachments }
    /// A Mac that predates uploads gets no + at all, never a start that would leave a photo out.
    private var canAttach: Bool { Self.offersPhotos(canUpload: tools.can(.uploads), macPicked: macPicked) }
    static func offersPhotos(canUpload: Bool, macPicked: Bool) -> Bool { canUpload && macPicked }
    private var uploading: Bool { attachments.isUploading(draft) }
    /// Something Cancel would lose: typed text, photos or a recording, not a blank field.
    private var hasDraft: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.items(draft).isEmpty || dictation.holdsRecording
    }
    private var room: Int { attach.room(draft, tools: tools) }
    private var models: [ModelOption] { tools.models(for: agent) }
    private var chosenModel: ModelOption? { models.first { $0.id == modelID } }
    private var accounts: [RemoteAccount] { model.accounts.accounts.filter { $0.provider == agent } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    ComposerField(text: Bindable(form).prompt, selection: $promptSelection, isFocused: $focused, placeholder: "What should it do?",
                                  label: "Prompt", minLines: 6, maxLines: nil, insets: .zero, drawer: attach.drawer, paste: attach.target)
                    PromptDictation(dictation: dictation, text: Bindable(form).prompt, selection: $promptSelection, focused: $focused, model: model,
                                    project: project?.name, shelf: draft)
                    if prompt.isEmpty, project == nil, !recent.isEmpty, macPicked {
                        suggestions
                    }
                }
                .padding(Space.m)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
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
                        // Escape closes the drawer first when it is up.
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
        // A fitted iPad sheet is as tall as the title bar, the prompt and recents (no less than room for the folder list
        // or a message in its place) and the chips.
        .frame(idealHeight: wide ? 56 + max(contentHeight, 300) + barHeight : nil)
        // A swipe down closes it with the draft kept for the next time; only Cancel discards.
        .interactiveDismissDisabled(starting || dictation.isBusy || attach.strip.holdsTouch)
        // On iPad a compose sheet as tall as what it holds; a phone's, and a narrow window's, fill the screen anyway.
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .attachments(attach, key: draft, tools: tools)
        .onChange(of: ObjectIdentifier(tools.attachments), initial: true) {
            if let held, held !== tools.attachments { held.rehome(draft, to: tools.attachments) }
            held = tools.attachments
        }
        .sensoryFeedback(.success, trigger: started)
        .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        .task(id: model.macID) { await load() }
        // Another Mac has its own folders, models and accounts.
        .onChange(of: macID) { project = nil; loading = true }
        .onChange(of: agent) { keepOffered() }
        .onChange(of: modelID) { keepOffered() }
        .onChange(of: prompt) { newDraftStarted() }
        .onAppear { focused = true }
        #if DEBUG
        .task { await debugLaunch() }
        #endif
    }

    #if DEBUG
    /// `--attach N` puts N generated photos in the tray, `--attach-failed` one that didn't upload, `--prompt-text` a
    /// prompt, `--drawer panel|large` opens the drawer: states for screenshots, reached without taps.
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

    private var recent: [RemoteProject] { Array(tools.projects.sorted { ($0.lastUsedAt ?? 0) > ($1.lastUsedAt ?? 0) }.prefix(5)) }

    /// Linear's suggestions: one tap sets the folder.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Recent")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(recent) { folder in
                Button { project = folder } label: { ProjectRow(project: folder) }
                    .buttonStyle(.plain)
            }
            if loadError != nil {
                Text("From earlier · couldn't refresh from \(model.mac.name)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Chips

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
                    // The draft stays: the same key makes a later Start the same session, never a second one.
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
                // In a regular-width sheet every chip shows, wrapping onto a second row rather than scrolling out of sight.
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

    /// The same + as the composer's: a tap for the menu, a hold for recent photos. No session yet, so no session files.
    private var attachButton: some View {
        AttachButton(surface: attach, key: draft, tools: tools, diameter: 44, glyph: 17, label: "Attach photos")
        .attachPopover(attach)
        .disabled(room == 0)
        .needsMac()
        .environment(model)
    }

    @ViewBuilder private var chipItems: some View {
        if asksMac { macChip }
        Button { picking = true } label: {
            ChipLabel(symbol: "folder", text: project?.name ?? "Folder", prominent: project == nil && macPicked)
        }
        .disabled(!macPicked)
        .accessibilityLabel(project.map { "Folder, \($0.name)" } ?? "Choose a folder")
        agentChip
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
            Picker(hosts.map(\.mac.kind).shared.titleNoun, selection: Binding { macID ?? (root.shown != nil ? model.macID : nil) } set: { macID = $0 }) {
                ForEach(hosts, id: \.macID) { mac in
                    Label(mac.mac.name, systemImage: "laptopcomputer").tag(Optional(mac.macID))
                }
            }
        } label: {
            ChipLabel(symbol: "laptopcomputer", text: macPicked ? model.mac.name : hosts.map(\.mac.kind).shared.titleNoun, prominent: !macPicked)
        }
        .accessibilityLabel(macPicked ? "\(model.mac.kind.titleNoun), \(model.mac.name)" : "Choose a \(hosts.map(\.mac.kind).shared.titleNoun)")
    }

    private var agentChip: some View {
        Menu {
            Picker("Agent", selection: Bindable(form).agent) {
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
        // From the options it already has, so a choice made while the refresh runs isn't overwritten after it.
        if tools.options != nil { seed() }
        async let options: Void = tools.loadOptions()
        loadError = nil
        do { try await tools.loadProjects() } catch { loadError = MacTools.message(error) }
        await options
        loading = false
        seed()
        if project == nil, tools.projects.count == 1 { project = tools.projects.first }
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
        if let id = last.accountID, accounts.count > 1, accounts.contains(where: { $0.id == id }) { accountID = id }
        worktree = last.worktree
    }

    private func keepOffered() {
        if let modelID, !models.contains(where: { $0.id == modelID }) { self.modelID = nil }
        if let effort, chosenModel?.efforts.contains(effort) != true { self.effort = nil }
        if let accountID, !accounts.contains(where: { $0.id == accountID }) { self.accountID = nil }
    }

    /// Gone for good: the photos that were waiting go with the sheet.
    /// Cancel, or Discard: the draft is gone for good, its photos with it.
    private func leave() {
        startTask?.cancel()
        // Thrown away, not finished: closing the sheet would otherwise send what's being said.
        dictation.cancel(refocus: false)
        let form = root.newSession, photos = draft, tray = attachments, app = root, requests = keys, undoable = hasDraft
        app.newSession = NewSessionForm()
        dismiss()
        guard undoable else { return tray.discard(photos) }
        // The photos wait out the Undo, so taking it brings back the draft exactly as it was. Never over a newer draft.
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
        // Start waits for the photos (the button is off meanwhile). One that failed stays on its tile with Retry: a start
        // without it would drop what the user chose.
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
        let startedOn = model.macID
        starting = true
        error = nil
        let tapped = Date.now
        startTask = Task {
            defer { starting = false; waitingForMac = false }
            do {
                let hosted = try await tools.start(request, key: key) { waitingForMac = true }
                model.transcripts.started(hosted.name, prompt: request.prompt ?? "", at: tapped)
                // The photos show on the first prompt's bubble until the Mac's own copy of the turn replaces it.
                _ = attachments.take(draft, for: model.transcripts.firstPrompts[hosted.name]?.id)
                started += 1
                // A recording that failed was left out by choice; its draft is gone with the form.
                dictation.cancel(refocus: false)
                ListPrefsStore.setNewSession(choices, mac: startedOn)
                root.newSession = NewSessionForm()
                dismiss()
                onStarted(hosted, model)
            } catch let failure as RemoteFailure where failure.error.code == .outcomeUnknown {
                // The first try may have started it; a new key is a new session, so only the user decides. The prompt
                // and the photos stay where they are.
                key = UUID().uuidString.lowercased()
                error = "This may or may not have reached \(model.mac.name). Check Sessions before starting again."
            } catch let failure as RemoteFailure where failure.error.details?["reason"] == "unknown_upload" {
                // The Mac no longer has a photo (it keeps them a week, and a sheet can sit open): the phone still does.
                attachments.reupload(draft)
                error = "A photo went up again. Start once it's done."
            } catch {
                // Nothing started: the prompt is still in the field and the photos are still in the tray.
                if !Task.isCancelled { self.error = MacTools.message(error) }
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
        .hoverEffect(.highlight)
    }
}

/// Views in rows, left to right, starting a new row when the next one would pass the width it is offered.
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

/// What New Session holds until it starts or is discarded. The app keeps it, not the sheet: a link or a notification
/// can close the sheet, and the prompt, the choices and the photos are there when it opens again.
@Observable
final class NewSessionForm {
    nonisolated deinit {}

    /// The Mac picked in the chip; nil until picked when several could start it.
    var macID: String?
    var prompt = ""
    var project: RemoteProject?
    var agent: AgentProvider = .claude
    var modelID: String?
    var effort: Effort?
    /// Asked for; used only in a folder with a git root.
    var worktree = false
    var accountID: String?
    /// The Mac whose last choices this draft took (`ListPrefsStore.newSession`), so a reopened draft keeps its own.
    var seeded: String?
    /// One key per session started, so a second tap can't make a second session.
    var key = UUID().uuidString.lowercased()
    /// The tray's key: photos wait under it until Start names them.
    let draft = "new-session-" + UUID().uuidString.lowercased()
}
