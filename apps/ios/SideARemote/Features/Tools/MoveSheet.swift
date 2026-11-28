import SideAProtocol
import SideARemoteKit
import SwiftUI

/// Move to…: where the session would go and what changes there, Move behind Face ID, then the hand-over until the session
/// runs on the other computer, which opens when this phone is paired with it. A working session goes after this turn, when
/// the sheet waits with it, or now.
struct MoveSheet: View {
    let session: RemoteSession
    @Environment(AppModel.self) private var model
    @Environment(AppRoot.self) private var root
    @Environment(\.openSession) private var openSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var computers: [RemoteComputer]?
    @State private var chosen: RemoteComputer.ID?
    @State private var preview: MovePreview?
    @State private var refusal: String?
    @State private var error: String?
    @State private var sending = false
    @State private var checking = false
    @State private var started: MoveRecord?
    /// Move was sent and no answer says whether it went.
    @State private var unsure = false
    @State private var key = SendKey<MoveRequest>()
    @State private var when: MoveRequest.When = .afterTurn
    @State private var cancelling = false

    /// The session as the host lists it now: its turn can end, or start, while the sheet is open.
    private var current: RemoteSession { model.sessions.session(session.id) ?? session }
    /// Nothing for an idle session, as every move asked before `moves.when`.
    private var asked: MoveRequest.When? { MoveWhen.asked(current, chosen: when, tools: model.tools) }
    /// A move that waited and that the host no longer lists was cancelled, here or on the computer itself.
    private var withdrawn: Bool { started.map { $0.state == .waiting && model.tools.moves.record($0.id) == nil } ?? false }
    private var computer: RemoteComputer? { computers?.first { $0.id == chosen } }
    /// The host's latest word on this move.
    private var record: MoveRecord? { started.map { model.tools.moves.record($0.id) ?? $0 } }
    private var destination: AppModel? { record.flatMap { root.model(for: $0.computer) } }
    private var landed: RemoteSession? {
        guard let record, record.state == .away, let destination else { return nil }
        return MoveLanding.session(for: record, in: destination.sessions.sessions)
    }

    var body: some View {
        NavigationStack {
            content
                .animation(Motion.smooth(reduceMotion), value: record?.state)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(sending)
        .sensoryFeedback(.success, trigger: record?.state) { _, new in new == .away }
        .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        .task { await loadComputers() }
        .task(id: chosen.map { MoveRequest(computer: $0, when: asked) }) { await loadPreview() }
        .task(id: record?.state) { await settled() }
        .onChange(of: landed?.id) { _, id in if id != nil { open() } }
        .onChange(of: withdrawn) { _, gone in if gone { dismiss() } }
    }

    private var title: String {
        (record?.computerName ?? computer?.name).map { "Move to \($0)" } ?? "Move Session"
    }

    @ViewBuilder private var content: some View {
        if let record {
            progress(record)
        } else if unsure {
            unknown(computer?.name ?? "the other computer")
        } else if let computers, computers.isEmpty {
            ContentUnavailableView("No Computers to Move To", systemImage: "desktopcomputer")
        } else if computers == nil, let error {
            ContentUnavailableView {
                Label("Can't Move It", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await loadComputers() } }.buttonStyle(.glass)
            }
        } else if computers == nil {
            ProgressView()
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            if let computers, computers.count > 1 {
                Section {
                    Picker("Computer", selection: $chosen) {
                        ForEach(computers) { computer in
                            Label(computer.name, systemImage: computer.symbol).tag(Optional(computer.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            if asked != nil { MoveWhenSection(session: current, when: $when) }
            if let refusal {
                Section { Label(refusal, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
            } else if let preview {
                facts(preview)
            } else if chosen != nil, error == nil {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .animation(Motion.smooth(reduceMotion), value: when)
    }

    @ViewBuilder private func facts(_ preview: MovePreview) -> some View {
        let account = MoveText.account(preview)
        if preview.landing != nil || preview.permissionMode != nil || account != nil {
            Section {
                if let landing = preview.landing {
                    LabeledContent("Folder") {
                        Text(MoveText.folder(landing))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if let mode = preview.permissionMode { LabeledContent("Mode", value: mode.title) }
                if let account { Text(account) }
            }
        }
    }

    @ViewBuilder private func progress(_ record: MoveRecord) -> some View {
        switch record.state {
        case .waiting:
            ContentUnavailableView {
                Label(MoveText.status(record), systemImage: "desktopcomputer.and.arrow.down")
            } description: {
                if let error { Text(error) }
            } actions: {
                if cancelling { ProgressView() } else { Button("Cancel Move") { cancel(record) }.buttonStyle(.glass) }
            }
        case .moving:
            busy(MoveText.status(record))
        case .away where destination != nil:
            busy("Opening on \(record.computerName)…")
        case .away:
            ContentUnavailableView(MoveText.status(record), systemImage: "checkmark.circle")
        case .unknown:
            unknown(record.computerName)
        default:
            ContentUnavailableView {
                Label("It didn't move", systemImage: "exclamationmark.triangle")
            } description: {
                Text(record.message ?? "It's still on \(model.mac.name).")
            } actions: {
                Button("Try Again") { tryAgain() }.buttonStyle(.glass)
            }
        }
    }

    private func busy(_ text: String) -> some View {
        ContentUnavailableView {
            Label { Text(text) } icon: { ProgressView().controlSize(.large) }
        }
    }

    private func unknown(_ name: String) -> some View {
        ContentUnavailableView {
            Label("It may be running on \(name)", systemImage: "questionmark.circle")
        } description: {
            if let error { Text(error) }
        } actions: {
            if checking { ProgressView() } else { Button("Check Again") { checkAgain() }.buttonStyle(.glass) }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if record != nil || unsure {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .confirmationAction) {
                if sending {
                    ProgressView()
                } else {
                    Button("Move") { move() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(preview == nil || refusal != nil)
                }
            }
        }
    }

    private func loadComputers() async {
        error = nil
        do {
            let list = try await model.tools.computers()
            computers = list
            if list.count == 1 { chosen = list.first?.id }
        } catch {
            self.error = MacTools.message(error)
        }
    }

    private func loadPreview() async {
        preview = nil
        refusal = nil
        guard let computer else { return }
        error = nil
        do {
            let answer = try await model.tools.movePreview(session.id, to: computer, when: asked)
            if !Task.isCancelled { preview = answer }
        } catch let failure as RemoteFailure where failure.error.code == .moveRefused {
            refusal = failure.error.message
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { self.error = MacTools.message(error) }
        }
    }

    private func move() {
        guard let computer, preview != nil, refusal == nil else { return }
        sending = true
        error = nil
        let asked = self.asked
        let sent = key.sending(MoveRequest(computer: computer.id, when: asked))
        Task {
            defer { sending = false }
            do {
                started = try await model.tools.move(current, to: computer, when: asked, key: sent)
                key.answered()
            } catch ToolError.cancelled {
            } catch let failure as RemoteFailure {
                key.answered()
                switch failure.error.code {
                case .outcomeUnknown: unsure = true
                case .moveRefused: refusal = failure.error.message
                default: error = MacTools.message(failure)
                }
            } catch {
                self.error = MacTools.message(error)
            }
        }
    }

    private func checkAgain() {
        checking = true
        error = nil
        Task {
            defer { checking = false }
            if let record {
                do { started = try await model.tools.checkMove(record.id) } catch { self.error = MacTools.message(error) }
                return
            }
            // No record came back, so the host's own list says whether the move went.
            await model.tools.loadMoves()
            if let found = session.conversationID.flatMap(model.tools.moves.record(conversation:)) { started = found }
            unsure = false
        }
    }

    private func tryAgain() {
        started = nil
        Task { await loadPreview() }
    }

    /// Cancelled, the host no longer lists it and the sheet closes; one that has started goes on here as a move under way.
    private func cancel(_ record: MoveRecord) {
        cancelling = true
        error = nil
        Task {
            defer { cancelling = false }
            do {
                if try await model.tools.cancelMove(record) { AccessibilityNotification.Announcement("Stays on \(model.mac.name)").post() }
            } catch {
                self.error = MacTools.message(error)
            }
        }
    }

    /// Says where the move stands, and asks the other computer for its list once the session runs there.
    private func settled() async {
        guard let record else { return }
        AccessibilityNotification.Announcement(MoveText.status(record)).post()
        if record.state == .away { await destination?.refreshSessions() }
    }

    /// The other computer's session, with whatever was typed here and not sent waiting in its field.
    private func open() {
        guard let destination, let landed else { return }
        model.handDraft(of: session.id, to: destination, as: landed.id)
        let route = Route.session(landed.id, mac: destination.macID)
        dismiss()
        openSession?(route)
    }
}
