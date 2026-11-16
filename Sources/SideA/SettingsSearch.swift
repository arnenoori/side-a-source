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

    /// The entries for a query, best first. Forgiving the way a search field should be: a term matches the start of a
    /// word as it's typed, the middle of one, two words run together ("menubar"), or a word a letter or two off
    /// ("notifcation"). Every term has to match; when no entry has them all, the ones with the most still show, since
    /// a near miss beats an empty window.
    static func matching(_ query: String, in entries: [SettingsEntry] = all) -> [SettingsEntry] {
        let terms = words(query)
        guard !terms.isEmpty else { return [] }
        let scored = entries.enumerated().compactMap { index, entry -> (entry: SettingsEntry, matched: Int, score: Int, index: Int)? in
            let scores = terms.compactMap(entry.score)
            return scores.isEmpty ? nil : (entry, scores.count, scores.reduce(0, +), index)
        }
        let most = scored.map(\.matched).max() ?? 0
        return scored.filter { $0.matched == most }
            .sorted { ($0.score, -$0.index) > ($1.score, -$1.index) }
            .map(\.entry)
    }

    /// Lowercased, accents dropped, split on anything that isn't a letter or digit: "5-hour" is "5" and "hour".
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// How well one term matches this entry, nil when it doesn't. The title counts for most, then the tab, then the
    /// other words someone might type for it.
    func score(_ term: String) -> Int? {
        let title = Self.words(title)
        let fields = [(title, 30), (Self.words(tab.title), 10), (Self.words(words), 0)]
        var best = fields.compactMap { field, bonus in field.compactMap { Self.quality(term, $0) }.max().map { $0 + bonus } }.max()
        // "menubar" for "menu bar".
        if term.count >= 4, title.count > 1, title.joined().contains(term) { best = max(best ?? 0, 50 + 30) }
        return best
    }

    /// Exact, then the start of the word, then inside it, then a typo.
    static func quality(_ term: String, _ word: String) -> Int? {
        if word == term { return 100 }
        if word.hasPrefix(term) { return 80 }
        if term.count >= 3, word.contains(term) { return 50 }
        let allowed = term.count >= 8 ? 2 : term.count >= 4 ? 1 : 0
        // A typo rarely lands on the first letter, and holding to it keeps short words from matching everything.
        guard allowed > 0, word.first == term.first else { return nil }
        if abs(word.count - term.count) <= allowed, distance(term, word, within: allowed) { return 30 }
        // Still typing the word, with a slip already in it.
        if word.count > term.count, distance(term, String(word.prefix(term.count)), within: allowed) { return 25 }
        return nil
    }

    /// Whether two words are within `limit` edits, where swapping two neighbouring letters is one edit.
    static func distance(_ a: String, _ b: String, within limit: Int) -> Bool {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= limit else { return false }
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) <= limit }
        var before = [Int](), last = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                row[j] = min(last[j] + 1, row[j - 1] + 1, last[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { row[j] = min(row[j], before[j - 2] + 1) }
            }
            before = last
            last = row
        }
        return last[b.count] <= limit
    }

    /// The title with what was typed in bold, where it appears as typed.
    func highlighted(_ query: String) -> AttributedString {
        var text = AttributedString(title)
        for term in Self.words(query) {
            var from = title.startIndex
            while let found = title.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: from..<title.endIndex) {
                if let range = Range(found, in: text) { text[range].inlinePresentationIntent = .stronglyEmphasized }
                from = found.upperBound
            }
        }
        return text
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
    ]
}

struct SettingsResults: View {
    let query: String
    /// The row the arrow keys are on; Return opens it.
    let selected: Int
    let pick: (SettingsTab) -> Void

    var body: some View {
        let results = SettingsEntry.matching(query)
        ScrollViewReader { scroll in
            List {
                // In the list, so nothing found reads where results would, not in the middle of the window.
                if results.isEmpty { Text("No Results").foregroundStyle(.secondary) }
                ForEach(Array(results.enumerated()), id: \.element) { index, entry in
                    Button { pick(entry.tab) } label: {
                        HStack {
                            Text(entry.highlighted(query))
                            Spacer()
                            Label(entry.tab.title, systemImage: entry.tab.symbol).foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(index == selected ? RoundedRectangle(cornerRadius: 6).fill(.selection).padding(.horizontal, 6) : nil)
                    .id(index)
                }
            }
            .onChange(of: selected) { scroll.scrollTo(selected) }
        }
    }
}
