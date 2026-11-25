import Observation
import SideAProtocol
import SideARemoteShared
import SwiftUI

@Observable
final class SessionActions {
    nonisolated deinit {}

    struct Port: Identifiable, Hashable {
        let session: SessionKey
        let port: Int
        var id: String { "\(session):\(port)" }
    }

    struct Terminal: Identifiable {
        let model: TerminalModel
        var id: String { model.name }
    }

    var terminal: Terminal?
    var restarting: RemoteSession?
    var continuing: RemoteSession?
    var quitting: RemoteSession?
    var quittingIdle: Int?
    var replying: RemoteSession?
    var renaming: RemoteSession?
    var newTitle = ""
    var stopping: Port?
    var previewing: Port?
    var started: HostedSession?
    private(set) var successes = 0
    var failure: String? { didSet { if failure != nil { failures += 1 } } }
    private(set) var failureTitle = "Couldn't Do That"
    private(set) var failures = 0
    private(set) var busy: Set<String> = []

    @ObservationIgnored weak var host: AppModel?
    @ObservationIgnored private(set) weak var mac: AppModel?

    var tools: MacTools? { (mac ?? host)?.tools }
    var model: AppModel? { mac ?? host }

    func on(_ model: AppModel) -> SessionActions {
        if mac !== model { mac = model }
        return self
    }

    func openTerminal(_ name: String) {
        guard let tools else { return }
        Task {
            let model = await tools.terminal(name)
            terminal = Terminal(model: model)
        }
    }

    func run(_ key: String, working: String? = nil, failed: String? = nil, _ work: @escaping (MacTools) async throws -> Void) {
        guard let tools, !busy.contains(key) else { return }
        busy.insert(key)
        let pill = working.map { Pill.working($0) }
        Task {
            defer {
                busy.remove(key)
                if let pill { Pill.end(pill) }
            }
            do { try await work(tools) } catch ToolError.cancelled {} catch {
                failureTitle = failed ?? "Couldn't Do That"
                failure = MacTools.message(error)
            }
        }
    }

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    func continueOnPhone(_ session: RemoteSession) {
        run(session.id) { tools in
            let hosted = try await tools.continueOnPhone(session.id)
            self.successes += 1
            self.started = hosted
        }
    }

    func showOnMac(_ name: String) {
        run("show-\(name)") { tools in
            try await tools.showOnMac(name)
            self.successes += 1
            Pill.show("Open on \(self.model?.mac.name ?? "the Mac")")
        }
    }

    static let quitIdleKey = "quit-idle"
    static let idleMinutes = 30

    static func idleCount(_ sessions: [RemoteSession], now: Date = .now) -> Int {
        sessions.filter { session in
            guard SessionPhase(session) == .idle, !session.headless, let at = session.statusAt else { return false }
            return now.timeIntervalSince1970 - at >= Double(idleMinutes * 60)
        }.count
    }

    static func quitAsks(_ session: RemoteSession) -> Bool {
        stopAsks(session) || !(session.ports ?? []).isEmpty
    }

    static func stopAsks(_ session: RemoteSession) -> Bool {
        [.working, .needsYou].contains(SessionPhase(session)) || (session.backgroundTasks ?? 0) > 0
    }

    func requestQuit(_ session: RemoteSession, undoable: Bool = false) {
        if Self.quitAsks(session) { quitting = session } else if undoable { quitAfterUndo(session) } else { quit(session) }
    }

    /// A quit can't be taken back, so the row leaves at once and the session quits only when its Undo runs out.
    private func quitAfterUndo(_ session: RemoteSession) {
        guard let model else { return }
        model.sessions.setLeaving(session.id, true)
        Pill.undoable("Quit \u{201C}\(model.tools.title(for: session))\u{201D}", expired: { self.on(model).quit(session, quiet: true) }) {
            model.sessions.setLeaving(session.id, false)
        }
    }

    func requestStop(_ port: Port) {
        if model?.sessions.session(port.session).map(Self.stopAsks) ?? true { stopping = port } else { stopServer(port) }
    }

    func quit(_ session: RemoteSession, quiet: Bool = false) {
        let model = model
        run(session.id) { tools in
            do { try await tools.quit(session.id) } catch {
                model?.sessions.setLeaving(session.id, false)
                throw error
            }
            self.successes += 1
            model?.sessions.markEnded([session.id])
            if !quiet { Pill.show("Session quit") }
        }
    }

    func quitIdle() {
        run(Self.quitIdleKey) { tools in
            let quit = try await tools.quitIdle(olderThanMinutes: Self.idleMinutes)
            self.successes += 1
            self.model?.sessions.markEnded(quit)
            Pill.show(String(localized: "Quit ^[\(quit.count) idle session](inflect: true)"))
        }
    }

    func setPinned(_ session: RemoteSession, _ pinned: Bool, undoable: Bool = true) {
        guard let conversation = session.conversationID else { return }
        let model = model
        run("pin-\(session.id)") { tools in
            _ = try await tools.change(conversation, HistoryChange(pinned: pinned))
            guard undoable, let model else { return }
            Pill.undoable(pinned ? "Pinned" : "Unpinned") { self.on(model).setPinned(session, !pinned, undoable: false) }
        }
    }

    func snooze(_ session: RemoteSession, _ choice: SessionSnooze.Choice?, until: Date? = nil, undoable: Bool = true) {
        guard let model, let tools else { return }
        let before = tools.snooze(of: session)
        run("snooze-\(session.id)", failed: choice == nil ? "Couldn't Wake It" : "Couldn't Snooze It") { tools in
            try await tools.snooze(session, choice, until: until ?? choice?.until())
            guard undoable else { return }
            // An older Mac answers a snooze it drops at once with none; there is nothing to undo then.
            let snoozed = tools.snooze(of: session)
            if choice != nil, snoozed == nil { return }
            let text = snoozed.map { "Snoozed · \($0.untilText)" } ?? "Woken"
            Pill.undoable(text) {
                self.on(model).snooze(session, before?.choice, until: before?.until.map { Date(timeIntervalSince1970: $0) }, undoable: false)
            }
        }
    }

    /// Out of History, as there; the Mac unpins what it archives, so Undo pins it again when it was pinned.
    func archive(_ session: RemoteSession) {
        guard let conversation = session.conversationID, let model, let tools else { return }
        let wasPinned = tools.isPinned(session)
        run("archive-\(session.id)", failed: "Couldn't Archive It") { tools in
            _ = try await tools.change(conversation, HistoryChange(archived: true))
            Pill.undoable("Archived") {
                self.on(model).run("archive-\(session.id)") { tools in
                    _ = try await tools.change(conversation, wasPinned ? HistoryChange(pinned: true) : HistoryChange(archived: false))
                }
            }
        }
    }

    func compact(_ session: RemoteSession) {
        run("compact-\(session.id)", working: "Compacting", failed: "Couldn't Compact") { tools in
            try await tools.compact(session.id)
            self.successes += 1
            Pill.show("Compacted")
        }
    }

    func review(_ session: RemoteSession) {
        run("review-\(session.id)", working: "Starting review", failed: "Couldn't Start the Review") { tools in
            try await tools.review(session.id)
            self.successes += 1
            Pill.show("Review started")
        }
    }

    func change(_ session: RemoteSession, _ change: SettingsChange, title: String) {
        run("settings-\(session.id)") { tools in
            let result = try await tools.change(session, change, title: title)
            self.successes += 1
            if result.nextTurn { self.model?.transcripts.notice("\(title.prefix(1).uppercased() + title.dropFirst()) from its next turn.", in: session.id) }
        }
    }

    func rename(_ session: RemoteSession, to title: String) {
        guard let conversation = session.conversationID else { return }
        run("rename-\(session.id)") { tools in
            _ = try await tools.change(conversation, HistoryChange(title: title.trimmingCharacters(in: .whitespacesAndNewlines)))
            self.successes += 1
        }
    }

    func stopServer(_ port: Port) {
        run(port.id) { tools in
            try await tools.stopServer(port.session, port: port.port)
            self.successes += 1
            Pill.show("Stopped :\(String(port.port))")
        }
    }

    func fork(_ session: RemoteSession) {
        run("fork-\(session.id)", working: "Forking", failed: "Couldn't Fork") { tools in
            let hosted = try await tools.fork(session)
            self.successes += 1
            Pill.show("Forked")
            self.started = hosted
        }
    }

    /// Forks by `fork(_:)` can start here: Claude forks a live conversation; Codex only one that isn't running,
    /// and a live row's always is.
    static func canFork(_ session: RemoteSession, tools: MacTools) -> Bool {
        tools.can(.hosted) && !session.headless && session.conversationID != nil && session.cwd != nil && session.agent == .claude
    }

    struct Resume: Hashable {
        var fork = false
        var worktree = false
        var model: String?
        var accountID: String?
    }

    func resume(_ past: PastSession, _ choice: Resume = Resume(), then: ((HostedSession) -> Void)? = nil) {
        guard let cwd = past.cwd else { return }
        let start = StartHosted(cwd: cwd, agent: past.agent, model: choice.model, worktree: choice.worktree,
                                accountID: choice.accountID, resume: past.id, fork: choice.fork)
        run(past.id) { tools in
            let hosted = try await tools.start(start, key: UUID().uuidString.lowercased())
            self.successes += 1
            if let then { then(hosted) } else { self.started = hosted }
        }
    }
}

extension EnvironmentValues {
    @Entry var onResumed: ((HostedSession) -> Void)?
}

private func present<T>(_ binding: Binding<T?>) -> Binding<Bool> {
    Binding { binding.wrappedValue != nil } set: { if !$0 { binding.wrappedValue = nil } }
}

extension View {
    func sessionActions() -> some View { modifier(SessionActionsHost()) }
}

private struct SessionActionsHost: ViewModifier {
    @Environment(AppModel.self) private var hostModel
    @State private var actions = SessionActions()
    @Environment(\.sidebarSelection) private var sidebarSelection

    private var model: AppModel { actions.model ?? hostModel }

    func body(content: Content) -> some View {
        @Bindable var actions = actions
        content
            .environment(actions)
            .onAppear { actions.host = hostModel }
            .sheet(item: $actions.restarting) { session in
                RestartSheet(session: session) { actions.started = $0 }
                    .environment(model)
            }
            .confirmationDialog("Continue on \(ThisDevice.kind)?", isPresented: Binding { actions.continuing != nil } set: { if !$0 { actions.continuing = nil } },
                                titleVisibility: .visible, presenting: actions.continuing) { session in
                Button("Continue on \(ThisDevice.kind)") { actions.continueOnPhone(session) }
            } message: { _ in
                Text("It closes on \(model.mac.name) and picks up here, in a terminal Side A keeps.")
            }
            .confirmationDialog("Quit \(actions.quitting?.title ?? "Session")?", isPresented: present($actions.quitting),
                                titleVisibility: .visible, presenting: actions.quitting) { session in
                Button("Quit Session", role: .destructive) { actions.quit(session) }
            }
            .confirmationDialog("Quit ^[\(actions.quittingIdle ?? 0) idle session](inflect: true)?", isPresented: present($actions.quittingIdle),
                                titleVisibility: .visible) {
                Button("Quit Idle Sessions", role: .destructive) { actions.quitIdle() }
            }
            .confirmationDialog("Stop the server on :\(String(actions.stopping?.port ?? 0))?", isPresented: present($actions.stopping),
                                titleVisibility: .visible, presenting: actions.stopping) { port in
                Button("Stop Server", role: .destructive) { actions.stopServer(port) }
            }
            .sheet(item: $actions.replying) { session in
                ComposerSheet(sessionID: session.id)
                    .environment(model)
            }
            .alert("Rename", isPresented: present($actions.renaming), presenting: actions.renaming) { session in
                TextField("Title", text: $actions.newTitle)
                Button("Rename") { actions.rename(session, to: actions.newTitle) }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $actions.previewing) { port in
                PreviewSheet(port: port)
                    .environment(model)
            }
            .navigationDestination(item: sidebarSelection == nil ? $actions.started : .constant(nil)) { StartingSessionView(started: $0).environment(model) }
            .onChange(of: actions.started) { _, started in
                guard let started, let sidebarSelection else { return }
                sidebarSelection.wrappedValue = .starting(started.name, mac: model.macID)
                actions.started = nil
            }
            .sensoryFeedback(.success, trigger: actions.successes)
            .sensoryFeedback(.error, trigger: actions.failures)
            .fullScreenCover(item: $actions.terminal) { terminal in
                TerminalScreen(name: terminal.model.name, model: terminal.model)
                    .environment(model)
            }
            .alert(actions.failureTitle, isPresented: Binding { actions.failure != nil } set: { if !$0 { actions.failure = nil } }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actions.failure ?? "")
            }
    }
}
