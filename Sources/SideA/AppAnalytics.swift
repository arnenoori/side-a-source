import Foundation
import Observation
import SideACore

@MainActor @Observable
final class AppAnalytics {
    private(set) var enabled: Bool
    private let defaults: UserDefaults
    private var visit = UUID()
    private var tasks: [UUID: URLSessionDataTask] = [:]
    private let session: URLSession
    private let allowed: Bool
    private let token: String?
    private let key = "sidea.anonymousUsage.enabled"
    init(defaults: UserDefaults = .standard, allowed: Bool = true,
         token: String? = Bundle.main.object(forInfoDictionaryKey: "SideAPostHogToken") as? String,
         session: URLSession? = nil) {
        self.defaults = defaults; self.allowed = allowed; self.token = token
        enabled = allowed && defaults.bool(forKey: "sidea.anonymousUsage.enabled")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        self.session = session ?? URLSession(configuration: configuration)
    }
    func setEnabled(_ value: Bool) {
        guard allowed else { return }
        enabled = value
        defaults.set(enabled, forKey: key)
        visit = UUID()
        if !enabled { for task in tasks.values { task.cancel() }; tasks.removeAll() }
        // No retroactive activity or events merely from choosing a preference.
    }
    func capture(_ event: AppMetric, provider: AgentProvider? = nil) {
        guard enabled, tasks.count < 10,
              let token,
              token.hasPrefix("phc_") else { return }
        let envelope = MetricEnvelope(token: token, visit: visit, event: event,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown", provider: provider)
        var request = URLRequest(url: URL(string: "https://us.i.posthog.com/i/v0/e/")!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(envelope)
        let id = UUID()
        let task = session.dataTask(with: request) { [weak self] _, _, _ in
            Task { @MainActor in self?.tasks.removeValue(forKey: id) }
        }
        tasks[id] = task; task.resume()
    }
}
