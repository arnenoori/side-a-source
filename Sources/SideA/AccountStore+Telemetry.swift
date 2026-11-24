import Foundation
import SideACore

struct TelemetryChecks {
    var statusAt = Date.distantPast
    var pricesAt = Date.distantPast
    var memoryAt = Date.distantPast
    var memoryNotifiedAt: Date?
    var outageNotified = UserDefaults.standard.string(forKey: "outageNotified")
}

extension AccountStore {
    static let statusPage = URL(string: "https://status.claude.com")!
    static let priceList = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    static let weeklyAlertKey = "weeklyAlert"
    static let weeklyAlertDefault = 80.0

    func checkTelemetry() {
        if Date().timeIntervalSince(telemetry.pricesAt) > 86400 {
            telemetry.pricesAt = Date()
            Task { await refreshPrices() }
        }
        if Date().timeIntervalSince(telemetry.statusAt) > 300 {
            telemetry.statusAt = Date()
            Task { await checkStatus() }
        }
        alertWeekly()
    }

    private func checkStatus() async {
        var request = URLRequest(url: Self.statusPage.appendingPathComponent("api/v2/summary.json"), timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let found = Outage.parse(data)
        if found != outage { outage = found }
        guard let found, telemetry.outageNotified != found.id else { return }
        telemetry.outageNotified = found.id
        UserDefaults.standard.set(found.id, forKey: "outageNotified")
        notify("Claude is having trouble", "\(found.name). Errors in your sessions may be Anthropic's, not your accounts'.")
        island.show(.limit, "Claude is having trouble", found.name)
    }

    private var pricesURL: URL { root.appendingPathComponent("runtime/prices.json") }

    private func refreshPrices() async {
        if APIPrice.published.isEmpty, let saved = try? Data(contentsOf: pricesURL) {
            let prices = APIPrice.parsePublished(saved)
            if !prices.isEmpty {
                APIPrice.published = prices
                pricesUpdated = (try? pricesURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
        }
        var request = URLRequest(url: Self.priceList, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let prices = APIPrice.parsePublished(data)
        guard prices.count >= 5 else { return }
        APIPrice.published = prices
        pricesUpdated = Date()
        try? data.write(to: pricesURL, options: .atomic)
    }

    /// The user's own line: one notification per account and week when weekly use passes it.
    private func alertWeekly() {
        let threshold: Double = PreferencesMirror.value(Self.weeklyAlertKey)
        guard threshold > 0 else { return }
        let before = UserDefaults.standard.dictionary(forKey: "weeklyAlerted") as? [String: Double] ?? [:]
        var sent = before
        let now = Date().timeIntervalSince1970
        for account in config.accounts where account.ready {
            guard let weekly = usage[account.id]?.weekly, weekly.percent >= threshold, let reset = weekly.resetsAt,
                  reset > now, sent[account.id] != reset else { continue }
            sent[account.id] = reset
            notify("\(account.name) passed \(Int(threshold))% of its week", "\(weekly.text(at: now)) used; it resets \(UsageBar.format(reset)).")
        }
        if sent != before { UserDefaults.standard.set(sent, forKey: "weeklyAlerted") }
    }

    func checkMemory() async {
        guard let level = MemoryPressure.currentLevel(), MemoryPressure.levelTight(level) else { memoryWarning = nil; return }
        struct Live: Decodable { struct Session: Decodable { let memory: Int? }; let sessions: [Session] }
        guard let data = try? await bridgeOutput(["sessions", "live"], timeout: 30, priority: .utility),
              let live = try? JSONDecoder().decode(Live.self, from: data) else { return }
        let pressure = MemoryPressure(sessionsMB: live.sessions.compactMap(\.memory).reduce(0, +), level: level)
        memoryWarning = pressure.tight ? pressure.line : nil
        guard pressure.tight, MemoryPressure.shouldNotify(now: Date(), last: telemetry.memoryNotifiedAt) else { return }
        telemetry.memoryNotifiedAt = Date()
        notify("Memory is tight", pressure.notification)
    }
}
