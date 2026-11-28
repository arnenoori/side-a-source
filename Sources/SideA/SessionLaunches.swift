import Foundation
import SideACore
import SideAProtocol
import SwiftUI

/// A session being started from the Mac. It exists from the moment Start is pressed, before the launcher has chosen
/// a tmux name and long before the agent has a conversation id, so the list has a row and the window has something
/// to show while the session boots. It ends when the session is listed, or with an error the row keeps.
struct Launch: Identifiable, Equatable {
    enum State: Equatable {
        /// The launcher hasn't answered.
        case launching
        /// The tmux session exists and the agent is coming up in it.
        case booting
        /// The agent is asking something before it can start: to trust the folder, or a screen that isn't moving.
        case attention(kind: String, text: String)
        case failed(String)
    }

    let id: UUID
    let request: StartHosted
    /// The launcher's retry key: a second try with it returns the session the first made, never another.
    let key: String
    let terminal: Bool
    /// Photos to start with, as paths on the Mac, and the branch a new worktree is cut from (nil: where the folder is).
    var images: [String] = []
    var base: String?
    var hosted: String?
    var state: State = .launching
    let at: Date
    /// When the launcher answered: the grace runs from here.
    var bootedAt: Date?

    /// A launch the Mac never lists stops claiming to be starting after this long, as on the phone.
    static let grace: TimeInterval = 120
    /// How often the Mac looks for the new session while one boots: closely at first, when it is most likely to
    /// appear, then at a pace that costs little if it is stuck at a prompt.
    static func look(after waited: Duration) -> Duration { waited < .seconds(20) ? .milliseconds(500) : .seconds(2) }

    var title: String { Self.title(prompt: request.prompt, folder: request.cwd) }

    var failure: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    var settled: Bool { failure != nil }

    /// The first line of the prompt, cut to a row's length; the folder's name for a session started without one.
    static func title(prompt: String?, folder: String) -> String {
        let line = (prompt ?? "").split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return URL(fileURLWithPath: folder).lastPathComponent }
        return line.count > 80 ? String(line.prefix(80)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    /// The live row that is this launch's session, once the Mac lists it with a conversation.
    func listed(in live: [LiveSession]) -> String? {
        guard let hosted else { return nil }
        return live.first { $0.hosted == hosted && $0.sessionID != nil }?.sessionID
    }

    func expired(at now: Date) -> Bool {
        guard let bootedAt, !settled else { return false }
        return now.timeIntervalSince(bootedAt) >= Self.grace
    }
}

extension SessionDesk {
    /// Launches the list still shows: one whose session the Mac already lists is that session's row.
    func shownLaunches(live: [LiveSession]) -> [Launch] {
        launches.filter { $0.listed(in: live) == nil }
    }

    var selected: Launch? { launches.first { $0.id == selectedLaunch } }

    func update(_ id: UUID, _ change: (inout Launch) -> Void) {
        guard let index = launches.firstIndex(where: { $0.id == id }) else { return }
        change(&launches[index])
    }

    func remove(_ id: UUID) {
        launches.removeAll { $0.id == id }
        held[id] = nil
        if selectedLaunch == id { selectedLaunch = nil }
    }
}

extension SessionStore {
    static let attentionListener = "sessions-window"

    /// New Session: the row and the window show it at once, and the launcher is awaited here, not by the sheet.
    /// Without hosting there is nothing to wait for: the agent is typed into a terminal tab, as before.
    func launch(_ start: StartHosted, terminal: Bool = true, select: Bool = true, images: [String] = [], base: String? = nil) {
        guard store.isDemo || (store.hostingWanted && store.hosted.available) else {
            return self.start(start) { [weak self] error in if let error { self?.error = error } }
        }
        var launch = Launch(id: UUID(), request: start, key: UUID().uuidString, terminal: terminal, at: .now)
        launch.images = images
        launch.base = start.worktree ? base : nil
        withAnimation(Ink.ease) { desk.launches.insert(launch, at: 0) }
        if select { self.select(launch.id) }
        run(launch.id)
    }

    func select(_ launch: UUID) {
        desk.selectedLaunch = launch
        selectedID = nil
        desk.composerFocus += 1
    }

    /// Try Again: the same request under the same key.
    func retry(_ id: UUID) {
        guard desk.launches.contains(where: { $0.id == id && $0.settled }) else { return }
        desk.update(id) { $0.state = $0.hosted == nil ? .launching : .booting; $0.bootedAt = $0.hosted == nil ? nil : .now }
        run(id)
    }

    /// Edit: the request goes back to the New Session sheet, and the failed row goes.
    func edit(_ id: UUID) {
        guard let launch = desk.launches.first(where: { $0.id == id }) else { return }
        desk.seed = launch.request
        desk.remove(id)
        creating = true
    }

    func dismiss(_ id: UUID) { withAnimation(Ink.ease) { desk.remove(id) } }

    /// Trust and Start. Claude's question is answered here; Codex's doesn't name its folder, so it is answered in the terminal.
    func trust(_ id: UUID) {
        guard let launch = desk.launches.first(where: { $0.id == id }), let name = launch.hosted else { return }
        Task {
            do {
                try await store.hosted.trust(name)
                desk.update(id) { if case .attention = $0.state { $0.state = .booting } }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func showLaunch(_ id: UUID) {
        guard !store.isDemo, let launch = desk.launches.first(where: { $0.id == id }), let name = launch.hosted else { return }
        attachOnce(name, cwd: launch.request.cwd, in: resumeTerminal)
    }

    private func run(_ id: UUID) {
        guard let launch = desk.launches.first(where: { $0.id == id }) else { return }
        listenForAttention()
        Task {
            if launch.hosted == nil {
                guard let name = await host(launch) else { return }
                desk.update(id) { $0.hosted = name; $0.state = .booting; $0.bootedAt = .now }
                // The demo starts nothing, so it opens and plays nothing.
                if !store.isDemo { Sounds.play(.spinUp) }
                if launch.terminal, !store.isDemo { attachOnce(name, cwd: launch.request.cwd, in: resumeTerminal) }
            }
            await adopt(id)
        }
    }

    /// Runs the launcher. Nil when it failed, with the reason on the row.
    private func host(_ launch: Launch) async -> String? {
        if store.isDemo { return "sa-demo-\(launch.key.prefix(4).lowercased())" }
        do throws(SessionCommands.Failure) {
            return try await Perf.start("launcher") { () async throws(SessionCommands.Failure) -> String in
                try await SessionCommands(store: store).start(launch.request, images: launch.images, key: launch.key, origin: "mac", base: launch.base)
            }
        } catch {
            desk.update(launch.id) { $0.state = .failed(error.macMessage) }
            return nil
        }
    }

    /// Looks for the session until the Mac lists it, then hands the window over to it. The file watcher usually
    /// finds it first; this is what makes sure of it, for the length of the grace and no longer.
    private func adopt(_ id: UUID) async {
        let began = SuspendingClock.now
        while let launch = desk.launches.first(where: { $0.id == id }), !launch.settled {
            if !store.isDemo { await refreshLive() }
            if let conversation = launch.listed(in: live) {
                Perf.took("start", "listed", began.duration(to: .now))
                return adopted(launch, as: conversation)
            }
            if launch.expired(at: .now), !store.isDemo {
                desk.update(id) { $0.state = .failed("It hasn't started. Look at it in the terminal.") }
                return
            }
            try? await Task.sleep(for: Launch.look(after: began.duration(to: .now)))
        }
    }

    private func adopted(_ launch: Launch, as conversation: String) {
        if let held = desk.held[launch.id], !held.isEmpty, (drafts[conversation] ?? "").isEmpty { drafts[conversation] = held }
        let watching = desk.selectedLaunch == launch.id
        desk.remove(launch.id)
        if watching { go(conversation) }
    }

    private func listenForAttention() {
        guard store.hosted.attentionListeners[Self.attentionListener] == nil else { return }
        store.hosted.attentionListeners[Self.attentionListener] = { [weak self] name, attention in
            guard let self, attention.kind == "trust" || attention.kind == "screen",
                  let launch = self.desk.launches.first(where: { $0.hosted == name && !$0.settled }) else { return }
            self.desk.update(launch.id) { $0.state = .attention(kind: attention.kind, text: attention.text) }
        }
    }
}

extension HostedSessions {
    /// Remote's listener. The Sessions window has its own, so a trust question reaches the Mac with Remote off.
    var onAttention: (@MainActor (String, Attention) -> Void)? {
        get {
            guard !attentionListeners.isEmpty else { return nil }
            return { [weak self] name, attention in self?.attentionListeners.values.forEach { $0(name, attention) } }
        }
        set { attentionListeners["remote"] = newValue }
    }
}
