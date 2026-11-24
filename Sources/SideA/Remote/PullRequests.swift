import Foundation
import SideACore

/// `gh` can take seconds and needs a sign-in, so it runs detached, at most once a minute per pull request; a Mac without
/// it, or signed out of it, sends the link alone and stops asking for ten minutes.
@MainActor
final class PullRequests {
    static let fresh: TimeInterval = 60
    static let restAfterRefusal: TimeInterval = 600
    static let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    typealias Check = (status: String?, conclusion: String?, state: String?)

    private var reads: [String: (pull: PullRequest, at: Date)] = [:]
    private var running: Set<String> = []
    private var resting: Date?
    var run: @Sendable (String, [String]) async -> ProcessRunner.Result = { executable, arguments in
        await Task.detached(priority: .utility) {
            await ProcessRunner.run(executable, arguments, environment: ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "NO_COLOR": "1"],
                                    timeout: 20, priority: .utility)
        }.value
    }
    var gh: () -> String? = { PullRequests.candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }
    var changed: (@MainActor () -> Void)?

    init(changed: (@MainActor () -> Void)? = nil) { self.changed = changed }

    func pull(_ url: String?, now: Date = Date()) -> PullRequest? {
        guard let url, Self.accepted(url) else { return nil }
        let known = reads[url]
        if known.map({ now.timeIntervalSince($0.at) >= Self.fresh }) ?? true { refresh(url, now: now) }
        return known?.pull ?? PullRequest(url: url)
    }

    /// The link comes from the transcript, which a repo's files can steer, and `gh` and the phone's browser both follow
    /// it. GitHub Enterprise hosts are left out: which ones `gh` is signed in to is only in its credentials file.
    nonisolated static func accepted(_ url: String) -> Bool {
        guard url.hasPrefix("https://"), let parts = URLComponents(string: url), parts.host?.lowercased() == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil else { return false }
        let path = parts.path.split(separator: "/")
        return path.count >= 4 && path[2] == "pull" && Int(path[3]) != nil
    }

    private func refresh(_ url: String, now: Date) {
        guard !running.contains(url), resting.map({ now >= $0 }) ?? true, let gh = gh() else { return }
        running.insert(url)
        // Stamped before it runs, so a read that fails waits its minute too.
        reads[url] = (reads[url]?.pull ?? PullRequest(url: url), now)
        let run = run
        Task { [weak self] in
            let result = await run(gh, ["pr", "view", url, "--json", "number,title,state,isDraft,statusCheckRollup"])
            self?.finish(url, result)
        }
    }

    private func finish(_ url: String, _ result: ProcessRunner.Result) {
        running.remove(url)
        guard result.status == 0, let pull = Self.parse(result.output, url: url) else {
            // gh exits 4 when it needs a sign-in.
            if result.launchError != nil || result.status == 4 || String(decoding: result.errors, as: UTF8.self).contains("gh auth login") {
                resting = Date().addingTimeInterval(Self.restAfterRefusal)
            }
            return
        }
        let before = reads[url]?.pull
        reads[url] = (pull, reads[url]?.at ?? Date())
        if before != pull { changed?() }
    }

    nonisolated static func parse(_ data: Data, url: String) -> PullRequest? {
        struct Item: Decodable { let status: String?; let conclusion: String?; let state: String? }
        // swiftlint:disable:next discouraged_optional_boolean -- gh leaves isDraft out for a pull request that was never a draft
        struct View: Decodable { let number: Int?; let title: String?; let state: String?; let isDraft: Bool?; let statusCheckRollup: [Item]? }
        guard let view = try? JSONDecoder().decode(View.self, from: data) else { return nil }
        let state: PullRequest.State? = switch view.state?.uppercased() {
        case "OPEN": view.isDraft == true ? .draft : .open
        case "MERGED": .merged
        case "CLOSED": .closed
        default: nil
        }
        let checks = summary((view.statusCheckRollup ?? []).map { ($0.status, $0.conclusion, $0.state) })
        return PullRequest(url: url, number: view.number, title: view.title, state: state, checks: checks)
    }

    /// A check run has `status` and `conclusion`; a commit status has only `state`.
    nonisolated static func summary(_ checks: [Check]) -> PullRequest.Checks? {
        guard !checks.isEmpty else { return nil }
        let failed: Set = ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "ERROR", "STARTUP_FAILURE"]
        let outcomes = checks.map { (($0.conclusion?.isEmpty == false ? $0.conclusion : nil) ?? $0.state ?? "").uppercased() }
        if outcomes.contains(where: failed.contains) { return .failing }
        let pending = checks.contains { check in
            if let status = check.status { return status.uppercased() != "COMPLETED" }
            return ["PENDING", "EXPECTED", ""].contains((check.state ?? "").uppercased())
        }
        return pending ? .pending : .passing
    }
}
