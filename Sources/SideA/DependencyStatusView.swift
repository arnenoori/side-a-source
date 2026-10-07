import SwiftUI
import SideACore

struct DependencyStatusView: View {
    @Bindable var store: AccountStore
    let provider: AgentProvider
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if compact && store.dependencies.ready(for: provider) && !store.checkingDependencies {
                Label("\(provider.cliName) is ready", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                if !store.checkingDependencies && !store.dependencies.ready(for: provider) {
                    Text("Install once:")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                row(store.dependencies.python, url: URL(string: "https://www.python.org/downloads/macos/")!)
                row(store.dependencies.agent(provider), url: provider.setupURL)
                if !store.dependencies.ready(for: provider) {
                    Button(store.checkingDependencies ? "Checking…" : "Check again") { Task { await store.refreshDependencies() } }
                        .disabled(store.checkingDependencies).font(.system(size: 12))
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refreshDependencies() }
        }
    }
    private func row(_ dependency: Dependency, url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: dependency.state == .ready ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(dependency.state == .ready ? .secondary : Color.deckOrange)
            Text(dependency.name)
            Spacer()
            if store.checkingDependencies { ProgressView().controlSize(.mini) }
            else if dependency.state == .ready { Text(dependency.version ?? "Ready").foregroundStyle(.secondary) }
            else { Link(dependency.state == .incompatible ? "Update ↗" : "Install ↗", destination: url) }
        }.font(.system(size: 12))
    }
}

struct UsagePreference: View {
    @Bindable var analytics: AppAnalytics
    var body: some View {
        Toggle(isOn: Binding(get: { analytics.enabled }, set: { analytics.setEnabled($0) })) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share anonymous usage")
                Text("Counts only. No accounts or code.").font(.caption).foregroundStyle(.secondary)
            }
        }.toggleStyle(.checkbox)
    }
}
