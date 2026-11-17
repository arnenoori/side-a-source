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
    @State private var loading = true
    @State private var picking = false
    @State private var discarding = false
    @State private var started = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowIsRegular) private var wide
    /// The prompt and recents' height, so a fitted iPad sheet is as tall as they are.
    @State private var contentHeight: CGFloat = 0
    @State private var barHeight: CGFloat = 0
    @FocusState private var focused: Bool
    @State private var attach = AttachSurface()
    /// The tray the photos are in, so a different Mac can have them sent to it.
    @State private var held: ComposerAttachments?

    /// The Macs that can start a session here.
    private var hosts: [AppModel] { root.macs.filter { $0.tools.can(.hosted) } }
    private var asksMac: Bool { hosts.count > 1 }
    private var model: AppModel {
        macID.flatMap(root.model(for:)) ?? (asksMac && root.shown == nil ? hosts.first : nil) ?? shown
    }
    private var tools: MacTools { model.tools }
    private var macPicked: Bool { macID != nil || !asksMac || root.shown != nil }
    private var canStart: Bool {
        project != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !starting && macPicked && !uploading
    }
    private var attachments: ComposerAttachments { tools.attachments }
    /// A Mac that predates uploads gets no + at all, never a start that would leave a photo out.
    private var canAttach: Bool { Self.offersPhotos(canUpload: tools.can(.uploads), macPicked: macPicked) }
    static func offersPhotos(canUpload: Bool, macPicked: Bool) -> Bool { canUpload && macPicked }
    private var uploading: Bool { attachments.isUploading(draft) }
    private var hasDraft: Bool { !prompt.isEmpty || !attachments.items(draft).isEmpty }
    private var room: Int { attach.room(draft, tools: tools) }
    private var models: [ModelOption] { tools.models(for: agent) }
    private var chosenModel: ModelOption? { models.first { $0.id == modelID } }
    private var accounts: [RemoteAccount] { model.accounts.accounts.filter { $0.provider == agent } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    TextField("What should it do?", text: Bindable(form).prompt, axis: .vertical)
                        .font(.body)
                        .lineLimit(6...)
                        .focused($focused)
                        .accessibilityLabel("Prompt")
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
                        .needsMac()
                        .environment(model)
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
                            .needsMac()
                            .environment(model)
                    }
                }
            }
            .sheet(isPresented: $picking) { ProjectPicker(selection: Bindable(form).project).environment(model) }
        }
        // A fitted iPad sheet is as tall as the title bar, the prompt and recents (no less than room for the folder list
        // or a message in its place) and the chips.
        .frame(idealHeight: wide ? 56 + max(contentHeight, 300) + barHeight : nil)
        .interactiveDismissDisabled(hasDraft || starting)
        // On iPad a compose sheet as tall as what it holds; a phone's, and a narrow window's, fill the screen anyway.
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .attachments(attach, key: draft, tools: tools, focused: $focused)
        .onChange(of: ObjectIdentifier(tools.attachments), initial: true) {
            if let held, held !== tools.attachments { held.rehome(draft, to: tools.attachments) }
            held = tools.attachments
        }
        .sensoryFeedback(.success, trigger: started)
        .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        .task(id: model.macID) { await load() }
        // Another Mac has its own folders, models and accounts.
        .onChange(of: macID) { project = nil; modelID = nil; effort = nil; accountID = nil; loading = true }
        .onChange(of: agent) { modelID = nil; effort = nil; accountID = nil }
        .onChange(of: modelID) { effort = nil }
        .onChange(of: project) { if project?.gitRoot == nil { worktree = false } }
        .onAppear { focused = true }
        #if DEBUG
        .task { await debugLaunch() }
        #endif
    }

    #if DEBUG
    /// `--attach N` puts N generated photos in the tray, `--attach-failed` one that didn't upload, `--prompt-text` a
    /// prompt, `--drawer menu|photos` opens the drawer: states for screenshots, reached without taps.
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
            attach.open(key: draft, tools: tools, reduceMotion: reduceMotion, options: nil)
            if mode == "photos" { try? await Task.sleep(for: .milliseconds(700)); attach.drawer.showPhotos() }
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
            AttachmentTray(session: draft, landing: attach.drawer.landing) { id, frame in attach.drawer.trayFrames[id] = frame }
                .environment(model)
                .padding(.horizontal, Space.m)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
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
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { attach.drawer.composerFrame = $0.insetBy(dx: Space.m, dy: 0) }
        }
        .padding(.vertical, Space.xs)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
        .animation(Motion.smooth(reduceMotion), value: error)
        .animation(Motion.smooth(reduceMotion), value: attachments.items(draft).map(\.id))
    }

    /// The same + as the composer's: the drawer grows out of it.
    private var attachButton: some View {
        Button {
            attach.open(key: draft, tools: tools, reduceMotion: reduceMotion, options: nil)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        // The drawer opens as this circle, so it stands aside while the drawer is up.
        .opacity(attach.drawer.hidesPlus ? 0 : 1)
        .animation(nil, value: attach.drawer.hidesPlus)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { attach.drawer.plusFrame = $0 }
        .disabled(room == 0)
        .needsMac()
        .environment(model)
        .accessibilityLabel("Attach photos")
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
        Menu {
            Picker("Model", selection: Bindable(form).modelID) {
                Text("Default").tag(String?.none)
                ForEach(models, id: \.id) { Text($0.title).tag(Optional($0.id)) }
            }
            if let chosenModel, !chosenModel.efforts.isEmpty {
                Picker("Effort", systemImage: "gauge.with.dots.needle.50percent", selection: Bindable(form).effort) {
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
            Picker("Mac Tab", selection: $openOnMac) {
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
        async let options: Void = tools.loadOptions()
        loadError = nil
        do { try await tools.loadProjects() } catch { loadError = MacTools.message(error) }
        await options
        loading = false
        if project == nil, tools.projects.count == 1 { project = tools.projects.first }
        if tools.agent(.claude)?.installed == false, tools.agent(.codex)?.installed == true { agent = .codex }
    }

    /// Gone for good: the photos that were waiting go with the sheet.
    /// Cancel, or Discard: the draft is gone for good, its photos with it.
    private func leave() {
        attachments.discard(draft)
        root.newSession = NewSessionForm()
        dismiss()
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
        let request = StartHosted(cwd: project.path, agent: agent, model: modelID, effort: effort?.rawValue, worktree: worktree,
                                  accountID: accountID, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                  attachments: photos, openOnMac: tools.can(.hostedShow) && openOnMac ? true : nil)
        starting = true
        error = nil
        let tapped = Date.now
        Task {
            defer { starting = false }
            do {
                let hosted = try await tools.start(request, key: key)
                model.transcripts.started(hosted.name, prompt: request.prompt ?? "", at: tapped)
                // The photos show on the first prompt's bubble until the Mac's own copy of the turn replaces it.
                _ = attachments.take(draft, for: model.transcripts.firstPrompts[hosted.name]?.id)
                started += 1
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
    var worktree = false
    var accountID: String?
    /// One key per session started, so a second tap can't make a second session.
    var key = UUID().uuidString.lowercased()
    /// The tray's key: photos wait under it until Start names them.
    let draft = "new-session-" + UUID().uuidString.lowercased()
}
