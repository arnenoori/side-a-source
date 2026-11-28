import AppKit
import SideAProtocol
import SwiftUI

extension LinkedComputer {
    /// Side A on a Mac serves a terminal stream and makes worktrees; `sidead` does neither yet.
    var hostsTerminals: Bool { endpoint.kind == .macos }
}

extension SessionStore {
    /// A tab here on `name`, a session hosted on `computer`: `attach` for a session that runs there.
    func attachRemote(_ name: String, on computer: LinkedComputer, in app: TerminalApp? = nil) {
        guard let peer = store.remote.computers.peer(computer.id, me: store.remote.mac) else {
            error = "\(computer.name) isn’t linked any more."
            return
        }
        // The session answers a colour query with this, so its own theme matches the tab's light or dark.
        let dark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        do {
            let opened = try LinkedTerminals.start(name, peer: peer, root: store.root, theme: TermTheme(appearance: dark ? .dark : .light))
            open(opened.command, bare: opened.command, cwd: nil, in: app ?? resumeTerminal, file: "remote-\(name)")
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Sessions running on the linked computers, at the foot of the session list: each opens here in a terminal tab.
struct ElsewhereSessions: View {
    struct Found: Identifiable, Equatable, Sendable {
        let computer: LinkedComputer
        let session: HostedSession
        var id: String { computer.id + "\n" + session.name }
    }

    private struct Reload: Equatable {
        let computers: [String]
        let creating: Bool
    }

    static let every: Duration = .seconds(20)

    let model: SessionStore
    @State private var found: [Found] = []
    @State private var ending: Found?
    @State private var startingOn: LinkedComputer?

    var body: some View {
        let computers = model.store.remote.computers.all.filter(\.hostsTerminals)
        VStack(alignment: .leading, spacing: 0) {
            // A session that moved there already has its own row here, with Bring Back.
            let moved = Set(model.store.remote.moves.records().compactMap { record in record.session.map { record.computer + "\n" + $0 } })
            let shown = found.filter { !moved.contains($0.id) }
            if !computers.isEmpty {
                Rectangle().fill(Ink.line).frame(height: 1)
                ForEach(shown) { row($0) }
                ForEach(computers) { computer in
                    Button("New Session on \(computer.name)…") { startingOn = computer }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
        .font(.system(size: 12.5))
        .sheet(item: $startingOn) { StartThereSheet(model: model, computerID: $0.id) }
        // Closing the New Session sheet asks again, so a session just started there shows at once.
        .task(id: Reload(computers: computers.map(\.id), creating: startingOn != nil)) { await watch(computers) }
        .confirmationDialog("End \(ending?.session.project ?? "this session") on \(ending?.computer.name ?? "the other computer")?",
                            isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }), presenting: ending) { item in
            Button("End Session", role: .destructive) { end(item) }
        }
    }

    private func row(_ item: Found) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.session.project).lineLimit(1)
                Text(Self.place(item)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Open") { model.attachRemote(item.session.name, on: item.computer) }
                .controlSize(.small)
                .accessibilityLabel("Open \(item.session.project) from \(item.computer.name) in \(model.resumeTerminal.title)")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contentShape(.rect)
        .contextMenu {
            Button("Open in \(model.resumeTerminal.title)") { model.attachRemote(item.session.name, on: item.computer) }
            Divider()
            Button("End Session…", role: .destructive) { ending = item }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "End Session") { ending = item }
    }

    static func place(_ item: Found) -> String {
        "On \(item.computer.name)" + (item.session.agent == .codex ? " · Codex" : "")
    }

    private func watch(_ computers: [LinkedComputer]) async {
        guard !computers.isEmpty else { found = []; return }
        while !Task.isCancelled {
            let next = await Self.load(computers, store: model.store)
            if !Task.isCancelled, next != found { found = next }
            try? await Task.sleep(for: Self.every)
        }
    }

    /// Every live hosted session on each computer that answers; one that doesn't has no rows until it does.
    static func load(_ computers: [LinkedComputer], store: AccountStore) async -> [Found] {
        let peers = computers.compactMap { computer in store.remote.computers.peer(computer.id, me: store.remote.mac).map { (computer, $0) } }
        return await withTaskGroup(of: (Int, [Found]).self) { group in
            for (index, (computer, peer)) in peers.enumerated() {
                group.addTask {
                    let hosted = (try? await peer.hosted()) ?? []
                    return (index, hosted.filter(\.alive).sorted { $0.createdAt > $1.createdAt }.map { Found(computer: computer, session: $0) })
                }
            }
            var lists = [[Found]](repeating: [], count: peers.count)
            for await (index, list) in group { lists[index] = list }
            return lists.flatMap { $0 }
        }
    }

    private func end(_ item: Found) {
        guard let peer = model.store.remote.computers.peer(item.computer.id, me: model.store.remote.mac) else { return }
        Task {
            do {
                try await peer.endHosted(item.session.name)
                found.removeAll { $0 == item }
                AccessibilityNotification.Announcement("Ended \(item.session.project) on \(item.computer.name)").post()
            } catch {
                model.error = peer.sentence(error)
            }
        }
    }
}
