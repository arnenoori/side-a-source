import SideAProtocol
import SwiftUI

/// Everything a turn changed (`GET /v1/sessions/{id}/turns/{turnID}/diff`): the Mac's note on what it leaves out,
/// then each file as the transcript's diff cards show it. A running turn reloads as the session moves.
struct TurnDiffPage: View {
    let sessionID: SessionKey
    let turnID: String
    @Environment(AppModel.self) private var model
    @State private var diff: TurnDiff?
    @State private var failure: String?

    private var session: RemoteSession? { model.sessions.session(sessionID) }

    var body: some View {
        Group {
            if let diff {
                if diff.files.isEmpty {
                    ContentUnavailableView {
                        Label(diff.running ? "No Changes Yet" : "No Changes", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        if let note = diff.note { Text(note) }
                    }
                } else {
                    files(diff)
                }
            } else if let failure {
                ContentUnavailableView {
                    Label("Couldn't Load Changes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try Again") { Task { await load() } }.buttonStyle(.glass)
                }
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .navigationTitle("Changes")
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .refreshable { await load() }
        .task(id: session?.statusAt) { await load() }
    }

    private var subtitle: String {
        guard let diff, !diff.files.isEmpty else { return "" }
        let added = diff.files.reduce(0) { $0 + $1.additions }, removed = diff.files.reduce(0) { $0 + $1.deletions }
        let files = diff.files.count == 1 ? "1 file" : "\(diff.files.count) files"
        return "\(files) · +\(added) −\(removed)" + (diff.running ? " · still working" : "")
    }

    private func files(_ diff: TurnDiff) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.m) {
                if let note = diff.note {
                    Label(note, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Space.xxs)
                }
                ForEach(diff.files, id: \.path) { file in
                    DiffCard(sourceID: "turn-\(turnID)-\(file.path)", diff: file)
                }
            }
            .padding(Space.m)
        }
    }

    private func load() async {
        do {
            let loaded = try await model.tools.turnDiff(sessionID, turn: turnID,
                                                        demo: model.transcripts.messages[sessionID] ?? [])
            diff = loaded; failure = nil
        } catch {
            if diff == nil { failure = MacTools.message(error) }
        }
    }
}
