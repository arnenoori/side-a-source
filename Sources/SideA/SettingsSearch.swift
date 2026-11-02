import SwiftUI

extension SettingsTab {
    var title: String {
        switch self {
        case .accounts: "Accounts"
        case .autopilot: "Autopilot"
        case .usage: "Usage"
        case .notifications: "Notifications"
        case .remote: "iPhone"
        case .setup: "Setup"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .accounts: "person.2"
        case .autopilot: "arrow.triangle.2.circlepath"
        case .usage: "chart.bar"
        case .notifications: "bell.badge"
        case .remote: "iphone"
        case .setup: "wrench.and.screwdriver"
        case .general: "gearshape"
        }
    }
}

struct SettingsEntry: Hashable {
    let title: String
    let tab: SettingsTab
    var words = ""

    static func matching(_ query: String, in entries: [SettingsEntry] = all) -> [SettingsEntry] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return [] }
        return entries.filter { entry in
            let text = "\(entry.title) \(entry.tab.title) \(entry.words)".lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
    }

    static let all: [SettingsEntry] = [
        .init(title: "Add Account", tab: .accounts, words: "sign in login new claude codex"),
        .init(title: "Sign in again", tab: .accounts, words: "login expired renew remove rename"),
        .init(title: "Accounts on your other Macs", tab: .accounts, words: "sync sign in here"),
        .init(title: "Autopilot", tab: .autopilot, words: "smart switch move rotate automatic"),
        .init(title: "Move at", tab: .autopilot, words: "threshold percent limit switch 5-hour weekly"),
        .init(title: "Follow Fable", tab: .autopilot, words: "model fable"),
        .init(title: "Pool mode", tab: .autopilot, words: "proxy route conversation accounts base url codex"),
        .init(title: "Test Pool", tab: .autopilot, words: "pool health check logins reachable combined limits room"),
        .init(title: "Share with my other Macs", tab: .autopilot, words: "pool tailscale hub join remote mac"),
        .init(title: "Answer with recommended after 1 minute", tab: .autopilot, words: "auto answer question"),
        .init(title: "Up next", tab: .autopilot, words: "schedule order queue"),
        .init(title: "Your day", tab: .autopilot, words: "timeline hours warm up"),
        .init(title: "This week", tab: .usage, words: "limits percent tokens"),
        .init(title: "Paid usage", tab: .usage, words: "extra credits billing cost money spend"),
        .init(title: "Tokens per day", tab: .usage, words: "chart history"),
        .init(title: "When you work", tab: .usage, words: "hours activity"),
        .init(title: "Dynamic Island", tab: .notifications, words: "notch island"),
        .init(title: "Claude Code requests", tab: .notifications, words: "notch permission allow deny hook"),
        .init(title: "Codex requests", tab: .notifications, words: "notch permission hook"),
        .init(title: "Sessions that finish", tab: .notifications, words: "notch done chime ready clear"),
        .init(title: "Include automated runs", tab: .notifications, words: "notch done claude -p script sdk pipeline headless"),
        .init(title: "Show on display", tab: .notifications, words: "notch screen monitor pointer"),
        .init(title: "Island shortcuts", tab: .notifications, words: "keyboard hotkey notch"),
        .init(title: "A session needs you", tab: .notifications, words: "banner alert waiting input"),
        .init(title: "An account's week passes", tab: .notifications, words: "banner alert weekly limit"),
        .init(title: "Sound effects", tab: .notifications, words: "volume audio click chime"),
        .init(title: "Pair an iPhone", tab: .remote, words: "remote phone mobile qr scan"),
        .init(title: "Reach this Mac from anywhere", tab: .remote, words: "relay remote tailscale connection wifi"),
        .init(title: "Switch in Terminal", tab: .setup, words: "shell zshrc sidea use cli"),
        .init(title: "Host terminal sessions", tab: .setup, words: "tmux shell"),
        .init(title: "Live limits from Claude Code", tab: .setup, words: "statusline"),
        .init(title: "React the moment a limit hits", tab: .setup, words: "hook rate limit"),
        .init(title: "Old conversations and worktrees", tab: .setup, words: "storage disk cleanup archive space"),
        .init(title: "Claude Code setup", tab: .setup, words: "mcp servers hooks skills agents"),
        .init(title: "Open at login", tab: .general, words: "startup launch"),
        .init(title: "Show only in the menu bar", tab: .general, words: "dock icon"),
        .init(title: "3D player", tab: .general, words: "disc"),
        .init(title: "Keep awake while agents work", tab: .general, words: "sleep caffeinate lid battery"),
        .init(title: "Sync with your other Macs", tab: .general, words: "icloud drive"),
        .init(title: "Updates", tab: .general, words: "version upgrade automatic install"),
        .init(title: "Search index", tab: .general, words: "session rebuild"),
        .init(title: "Privacy", tab: .general, words: "analytics diagnostics"),
        .init(title: "Guided tour", tab: .general, words: "help onboarding"),
        .init(title: "Remove Side A", tab: .general, words: "uninstall delete"),
    ]
}

struct SettingsResults: View {
    let query: String
    let pick: (SettingsTab) -> Void

    var body: some View {
        let results = SettingsEntry.matching(query)
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(results, id: \.self) { entry in
                Button { pick(entry.tab) } label: {
                    HStack {
                        Text(entry.title)
                        Spacer()
                        Label(entry.tab.title, systemImage: entry.tab.symbol).foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
