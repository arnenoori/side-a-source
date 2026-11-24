import SideAProtocol
import SwiftUI

struct PastSessionView: View {
    @Environment(AppModel.self) private var model
    let past: PastSession
    var match: String?
    @State private var started: HostedSession?

    var body: some View {
        if let started {
            StartingSessionView(started: started)
        } else {
            TranscriptView(sessionID: past.id, past: past, match: match)
                .environment(\.onResumed) { started = $0 }
                .overlay {
                    if model.isDemo && model.transcripts.messages[past.id]?.isEmpty != false {
                        ContentUnavailableView("Transcript on the Mac", systemImage: "text.bubble",
                                               description: Text("Pair a Mac to read past sessions."))
                    }
                }
        }
    }
}

struct ResumeBar: View {
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions
    @Environment(\.onResumed) private var onResumed
    let past: PastSession

    private var accounts: [RemoteAccount] { model.accounts.accounts.filter { $0.provider == past.agent } }
    private var models: [ModelOption] { model.tools.models(for: past.agent) }

    var body: some View {
        if model.tools.can(.hosted), past.cwd != nil {
            GlassEffectContainer(spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    if actions.isBusy(past.id) {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .glassEffect(.regular, in: .capsule)
                    } else {
                        start("Resume", systemImage: "play.fill", fork: false)
                            .buttonStyle(.glassProminent)
                        start("Fork", systemImage: "arrow.triangle.branch", fork: true)
                            .buttonStyle(.glass)
                        if hasOptions { moreMenu }
                    }
                }
                .controlSize(.large)
            }
            .padding(.horizontal, Space.m)
            .padding(.bottom, Space.xs)
            .task { await model.tools.loadOptions() }
        }
    }

    private var hasOptions: Bool { accounts.count > 1 || past.branch != nil || !models.isEmpty }

    @ViewBuilder private func options(fork: Bool) -> some View {
        if accounts.count > 1 {
            Menu("On Account", systemImage: "person.crop.circle") {
                ForEach(accounts) { account in
                    Button(account.name) { actions.on(model).resume(past, .init(fork: fork, accountID: account.id), then: onResumed) }
                }
            }
        }
        if past.branch != nil {
            Button("In a New Worktree", systemImage: "arrow.triangle.branch") { actions.on(model).resume(past, .init(fork: fork, worktree: true), then: onResumed) }
        }
        if !models.isEmpty {
            Menu("Model", systemImage: "cpu") {
                ForEach(models, id: \.id) { option in
                    Button(option.title) { actions.on(model).resume(past, .init(fork: fork, model: option.id), then: onResumed) }
                }
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Section("Resume") { options(fork: false) }
            Section("Fork") { options(fork: true) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(minWidth: 24)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .accessibilityLabel("More Ways to Resume")
    }

    private func start(_ title: String, systemImage: String, fork: Bool) -> some View {
        Menu {
            options(fork: fork)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        } primaryAction: {
            actions.on(model).resume(past, .init(fork: fork), then: onResumed)
        }
        .menuStyle(.button)
    }
}
