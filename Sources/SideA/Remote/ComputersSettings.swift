import SideAProtocol
import SwiftUI

/// The computers this Mac can send sessions to.
struct ComputersSection: View {
    let remote: RemoteController
    @State private var linking = false
    @State private var unlinking: LinkedComputer?
    @AppStorage(MoveSettings.acceptsKey) private var accepts = true
    @AppStorage(MoveSettings.envKey) private var includesEnv = false
    @AppStorage(MoveSettings.standbyKey) private var standby = ""

    var body: some View {
        Section("Computers") {
            ForEach(remote.computers.all) { computer in
                LabeledContent {
                    Button("Unlink") { unlinking = computer }
                        .accessibilityLabel("Unlink \(computer.name)")
                } label: {
                    Label(computer.name, systemImage: "desktopcomputer")
                }
            }
            LabeledContent {
                Button("Link a Computer…") { linking = true }
            } label: {
                if remote.computers.all.isEmpty { Label("No computer yet", systemImage: "desktopcomputer").foregroundStyle(.secondary) }
            }
            if !remote.computers.all.isEmpty {
                Toggle("Accept Sessions", isOn: $accepts)
                Toggle("Include Ignored .env Files", isOn: $includesEnv)
                Picker("Standby", selection: $standby) {
                    Text("Off").tag("")
                    ForEach(remote.computers.all) { Text($0.name).tag($0.id) }
                }
                .onChange(of: standby) { Task { await remote.moves.checkpointAll() } }
            }
        }
        .sheet(isPresented: $linking) { LinkComputerSheet(remote: remote) }
        .confirmationDialog("Unlink \(unlinking?.name ?? "")?", isPresented: Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } })) {
            Button("Unlink", role: .destructive) { if let computer = unlinking { remote.computers.remove(computer.id, controller: remote) }; unlinking = nil }
        } message: {
            Text("Neither computer will be able to send the other sessions.")
        }
    }
}

/// Links this Mac to another with the pairing link the other one shows, the same way a phone pairs.
struct LinkComputerSheet: View {
    let remote: RemoteController
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var pending: LinkedComputers.Pending?
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let pending {
                Text("Check \(pending.name)").font(.title2.weight(.semibold))
                Text("If it shows these digits, click Pair there.").foregroundStyle(.secondary)
                Text(PairingTranscript.display(pending.code))
                    .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(pending.code.map(String.init).joined(separator: " "))
            } else {
                Text("Link a Computer").font(.title2.weight(.semibold))
                Text("On the other computer, open Side A’s Remote settings, click Pair, then Copy Link. A linked computer can start sessions on the other, so link only your own.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Pairing link", text: $link).textFieldStyle(.roundedBorder).onSubmit(start)
            }
            if let failure { Text(failure).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                if pending == nil {
                    Button("Link", action: start).keyboardShortcut(.defaultAction).disabled(link.isEmpty || working)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func start() {
        guard !working else { return }
        working = true
        failure = nil
        Task {
            do {
                let pending = try await remote.computers.begin(link: link, me: remote.mac)
                self.pending = pending
                _ = try await remote.computers.finish(pending, controller: remote)
                dismiss()
            } catch {
                pending = nil
                failure = (error as? LocalizedError)?.errorDescription ?? "The other computer didn’t accept the link. Start again there and copy a new link."
            }
            working = false
        }
    }

    private func cancel() {
        if let pending { Task { await remote.computers.cancel(pending) } }
        dismiss()
    }
}

/// Offers a hosted session's move to each linked computer, working or not; the sheet confirms it. While a move waits
/// for the session's turn to end, the menu cancels it instead.
struct MoveMenu: View {
    let store: AccountStore
    let session: LiveSession

    var body: some View {
        let computers = store.remote.computers.all
        let moves = store.remote.moves
        if let waiting = moves.waitingMove(for: session.sessionID), !moves.firing.contains(waiting.id) {
            Button("Cancel Move to \(waiting.computerName)") { moves.cancel(waiting.id) }
        } else if !computers.isEmpty, Moves.refusal(session, when: .afterTurn) == nil {
            Menu("Move to") {
                ForEach(computers) { computer in
                    Button("\(computer.name)…") { store.remote.moves.proposal = Moves.Proposal(session: session, computer: computer) }
                }
                Divider()
                ForEach(computers) { computer in
                    Button("All Idle Sessions to \(computer.name)") { moveAll(to: computer) }
                    Button(working ? "All Sessions to \(computer.name) and Sleep…" : "All Sessions to \(computer.name) and Sleep") { moveAndSleep(to: computer) }
                }
            }
        }
    }

    private var working: Bool { store.sessions.live.contains { $0.hosted != nil && $0.status != "idle" } }
}

extension MoveMenu {
    /// Leaving: every hosted session that is idle goes, one after another; what stays is named with its reason.
    func moveAll(to computer: LinkedComputer) {
        guard let peer = store.remote.computers.peer(computer.id, me: store.remote.mac) else { return }
        Task {
            let stayed = await store.remote.moves.sendAll(store.sessions.live.filter { Moves.refusal($0) == nil }, to: peer)
            await store.sessions.refreshLive()
            if let first = stayed.first {
                store.error = stayed.count == 1 ? "\(first.session.title ?? "One session") stayed here: \(first.reason)" : "\(stayed.count) sessions stayed here. \(first.reason)"
            }
        }
    }

    /// Move and Sleep: with sessions working, the person first picks how they go.
    func moveAndSleep(to computer: LinkedComputer) {
        if working { store.remote.moves.sleepProposal = computer } else { Self.leave(store, to: computer, working: .afterTurn) }
    }

    static func leave(_ store: AccountStore, to computer: LinkedComputer, working: MoveRequest.When) {
        guard let peer = store.remote.computers.peer(computer.id, me: store.remote.mac) else { store.error = "\(computer.name) isn’t linked any more."; return }
        Task {
            let sessions = await store.sessions.freshLive() ?? store.sessions.live
            await store.remote.moves.leaveAndSleep(sessions, to: peer, working: working)
            await store.sessions.refreshLive()
        }
    }
}

/// Presents the move sheet, and Move and Sleep's questions, from wherever the Sessions window is.
struct MoveSheetHost: ViewModifier {
    let store: AccountStore

    func body(content: Content) -> some View {
        let moves = store.remote.moves
        content.sheet(item: Binding(get: { moves.proposal }, set: { moves.proposal = $0 })) { MoveSheet(store: store, proposal: $0) }
            .modifier(MoveAndSleepHost(store: store))
    }
}

/// What a move will do, asked of both computers before anything stops, and the button that does it.
struct MoveSheet: View {
    let store: AccountStore
    let proposal: Moves.Proposal
    @Environment(\.dismiss) private var dismiss
    @State private var preview: MovePreview?
    @State private var failure: String?
    @State private var unknown = false
    @State private var moving = false
    /// For a working session: when it goes, and the move asked for from here once it has been.
    @State private var when: MoveRequest.When = .afterTurn
    @State private var requested: String?

    private var name: String { proposal.computer.name }
    private var moves: Moves { store.remote.moves }
    private var working: Bool { proposal.session.status != "idle" }
    private var waits: Bool { requested.map { moves.waiting[$0] != nil && !moves.firing.contains($0) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move to \(name)").font(.system(size: 15, weight: .semibold))
            if working, requested == nil {
                Picker("When", selection: $when) {
                    Text("After This Turn").tag(MoveRequest.When.afterTurn)
                    Text("Now").tag(MoveRequest.When.now)
                }
                .pickerStyle(.segmented).fixedSize()
                if when == .now { Text("Now interrupts its turn, so the tool call in progress is cut off.").font(.system(size: 12.5)).foregroundStyle(.secondary) }
            }
            if waits {
                Label("Moves when this turn ends", systemImage: "clock").font(.system(size: 12.5))
            } else if let preview {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    if let landing = preview.landing { fact("Lands in", (landing as NSString).abbreviatingWithTildeInPath) }
                    if let mode = preview.permissionMode { fact("Permissions", mode == .default ? "Asks before acting" : mode.rawValue) }
                    if let line = Self.account(preview, computer: name) { fact("Account", line) }
                    if MoveSettings.includesEnv { fact("Includes", "Ignored .env files") }
                }
                .font(.system(size: 12.5))
            } else if failure == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
            }
            if let failure { Label(failure, systemImage: "exclamationmark.circle").font(.system(size: 12.5)).foregroundStyle(unknown ? .primary : .secondary) }
            HStack {
                Spacer()
                if waits {
                    Button("Cancel Move") { if let requested { moves.cancel(requested) } }
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(unknown ? "Close" : "Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    if unknown {
                        Button("Check Again") { check() }.keyboardShortcut(.defaultAction).disabled(moving)
                    } else {
                        Button(moveTitle) { move() }.keyboardShortcut(.defaultAction).disabled(preview == nil || moving || requested != nil)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .task(id: when) { await load() }
        .onChange(of: outcome) { _, outcome in follow(outcome) }
    }

    private var moveTitle: String { moving || requested != nil ? "Moving…" : !working ? "Move" : when == .now ? "Move Now" : "Move After This Turn" }

    private enum Outcome: Equatable { case moved, failed, unknown, cancelled }

    /// How the move asked for from this sheet ended; nil while it waits or runs.
    private var outcome: Outcome? {
        guard let requested, moves.waiting[requested] == nil else { return nil }
        if moves.failures[requested] != nil { return .failed }
        switch moves.journal[requested]?.step {
        case .away?: return .moved
        case .unknown?: return .unknown
        case nil: return .cancelled
        default: return nil
        }
    }

    private func follow(_ outcome: Outcome?) {
        guard let requested, let outcome else { return }
        switch outcome {
        case .moved:
            AccessibilityNotification.Announcement("Moved to \(name)").post()
            Task { await store.sessions.refreshLive() }
            dismiss()
        case .failed:
            failure = moves.failures[requested]?.message
            moving = false
            self.requested = nil
        case .unknown:
            unknown = true
            failure = "It may be running on \(name)."
            moving = false
        case .cancelled:
            dismiss()
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func account(_ preview: MovePreview, computer: String) -> String? {
        switch preview.login {
        case .some(.sent): "Signs \(computer) in to \(preview.account ?? "this account") and stops using it here"
        case .some(.other): "Runs on \(computer)’s own account"
        default: nil
        }
    }

    private var peer: (any MovePeer)? { moves.peer(proposal.computer.id) }

    private func load() async {
        guard let peer else { failure = "\(name) isn’t linked any more."; return }
        preview = nil
        failure = nil
        do {
            preview = try await moves.preview(proposal.session, to: peer, os: proposal.computer.endpoint.os, when: working ? when : .idle)
        } catch { failure = error.localizedDescription }
    }

    private func move() {
        guard let peer, !moving else { return }
        moving = true
        failure = nil
        if working { return request(to: peer) }
        Task {
            do {
                try await moves.send(proposal.session, to: peer)
                await store.sessions.refreshLive()
                AccessibilityNotification.Announcement("Moved to \(name)").post()
                dismiss()
            } catch MoveFailure.unknown {
                unknown = true
                failure = "It may be running on \(name)."
            } catch {
                failure = error.localizedDescription
                await store.sessions.refreshLive()
            }
            moving = false
        }
    }

    private func check() {
        moving = true
        Task {
            await moves.settle()
            await store.sessions.refreshLive()
            moving = false
            if moves.ownership(of: proposal.session.sessionID ?? "") != .unknown(peer: proposal.computer.id) { dismiss() }
        }
    }

    /// A working session: After This Turn is remembered and the sheet shows it waiting; Now stops the turn and moves.
    private func request(to peer: any MovePeer) {
        let when = when
        Task {
            do {
                requested = try await moves.request(proposal.session, to: peer, when: when).id
                if when == .afterTurn {
                    moving = false
                    AccessibilityNotification.Announcement("Moves to \(name) when this turn ends").post()
                }
            } catch {
                failure = error.localizedDescription
                moving = false
            }
        }
    }
}

/// Sessions that are on another computer, at the foot of the session list: where each is, and the way back.
struct AwaySessions: View {
    let store: AccountStore
    @State private var asking: Set<String> = []
    @State private var copying: StandbyCopy?
    @State private var reclaiming: MoveRecord?

    var body: some View {
        // A waiting move's session still runs here, and its own row says where it goes.
        let records = store.remote.moves.records().filter { $0.state != .failed && $0.state != .waiting }
        let copies = store.remote.moves.copies()
        if !records.isEmpty || !copies.isEmpty || store.remote.moves.sleepsAfter != nil {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Ink.line).frame(height: 1)
                SleepsAfterRow(moves: store.remote.moves)
                ForEach(copies) { copy in
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(copy.title ?? copy.project ?? "Session").lineLimit(1)
                            Text("From \(copy.computerName), \(Date(timeIntervalSince1970: copy.at), format: .relative(presentation: .named))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if asking.contains(copy.conversationID) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Continue as a Copy…") { copying = copy }.controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                }
                ForEach(records) { record in
                    HStack(spacing: 8) {
                        Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.title ?? record.project ?? "Session").lineLimit(1)
                            Text(Self.place(record)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if record.state == .moving || asking.contains(record.id) {
                            ProgressView().controlSize(.small)
                        } else if record.state == .unknown {
                            Button("Check Again") { check(record) }.controlSize(.small)
                        } else {
                            Button("Bring Back") { bring(record) }.controlSize(.small)
                                .accessibilityLabel("Bring \(record.title ?? "the session") back from \(record.computerName)")
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .contentShape(.rect)
                    // One button a row, so the title keeps its room in a narrow list; the rarer action is in the menu.
                    .contextMenu {
                        if record.state == .unknown { Button("Run Here…") { reclaiming = record } }
                        if record.state == .away, let open = opener(record) { Button("Open in \(store.sessions.resumeTerminal.title)", action: open) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityActions {
                        if record.state == .unknown { Button("Run Here") { reclaiming = record } }
                        if record.state == .away, let open = opener(record) { Button("Open in Terminal", action: open) }
                    }
                }
            }
            .font(.system(size: 12.5))
            .confirmationDialog("Continue a copy here?", isPresented: Binding(get: { copying != nil }, set: { if !$0 { copying = nil } }), presenting: copying) { copy in
                Button("Continue as a Copy") { continueCopy(copy) }
            } message: { copy in
                Text("If \(copy.computerName) is still running this session, both will work, and anything they do outside the repository happens twice.")
            }
            .confirmationDialog("Run it here?", isPresented: Binding(get: { reclaiming != nil }, set: { if !$0 { reclaiming = nil } }), presenting: reclaiming) { record in
                Button("Run Here") { Task { await store.remote.moves.runHere(record.id); await store.sessions.refreshLive() } }
            } message: { record in
                Text("If \(record.computerName) did start this session, it will run on both.")
            }
        }
    }

    private func continueCopy(_ copy: StandbyCopy) {
        asking.insert(copy.conversationID)
        Task {
            do { _ = try await store.remote.moves.continueCopy(of: copy.conversationID) } catch { store.error = error.localizedDescription }
            await store.sessions.refreshLive()
            asking.remove(copy.conversationID)
        }
    }

    /// Opens the moved session's terminal here, when the computer it is on serves one.
    private func opener(_ record: MoveRecord) -> (() -> Void)? {
        guard let name = record.session, let computer = store.remote.computers.all.first(where: { $0.id == record.computer && $0.hostsTerminals }) else { return nil }
        return { store.sessions.attachRemote(name, on: computer) }
    }

    static func place(_ record: MoveRecord) -> String {
        switch record.state {
        case .moving: "Moving to \(record.computerName)…"
        case .unknown: "May be running on \(record.computerName)"
        default: "On \(record.computerName)"
        }
    }

    private func check(_ record: MoveRecord) {
        asking.insert(record.id)
        Task {
            _ = await store.remote.moves.check(record.id)
            await store.sessions.refreshLive()
            asking.remove(record.id)
        }
    }

    private func bring(_ record: MoveRecord) {
        guard let peer = store.remote.computers.peer(record.computer, me: store.remote.mac) else { store.error = "\(record.computerName) isn’t linked any more."; return }
        asking.insert(record.id)
        Task {
            do { _ = try await peer.bring(record.conversationID, to: store.remote.mac.id) } catch { store.error = Moves.sentence(error, peer: record.computerName) }
            // It arrives as a move from the other computer; the row goes when it has.
            _ = await eventuallyGone(record.id)
            await store.sessions.refreshLive()
            asking.remove(record.id)
        }
    }

    private func eventuallyGone(_ id: String) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline {
            if store.remote.moves.record(id) == nil { return true }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return false }
        }
        return false
    }
}
