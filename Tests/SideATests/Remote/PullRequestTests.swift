import Foundation
@testable import SideA
import SideACore
import Testing

@Test func pullRequestStateAndChecksComeFromGhView() throws {
    let view = #"""
    {"number":412,"title":"Fix the island layout","state":"OPEN","isDraft":false,"statusCheckRollup":[
      {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"lint","status":"IN_PROGRESS","conclusion":""},
      {"__typename":"StatusContext","context":"ci/deploy","state":"SUCCESS"}]}
    """#
    let pull = try #require(PullRequests.parse(Data(view.utf8), url: "https://github.com/you/app/pull/412"))
    #expect(pull == PullRequest(url: "https://github.com/you/app/pull/412", number: 412, title: "Fix the island layout", state: .open, checks: .pending))

    #expect(PullRequests.summary([("COMPLETED", "SUCCESS", nil), (nil, nil, "SUCCESS")]) == .passing)
    #expect(PullRequests.summary([("COMPLETED", "FAILURE", nil), ("QUEUED", nil, nil)]) == .failing)
    #expect(PullRequests.summary([(nil, nil, "ERROR")]) == .failing)
    #expect(PullRequests.summary([(nil, nil, "PENDING")]) == .pending)
    #expect(PullRequests.summary([]) == nil)

    let draft = try #require(PullRequests.parse(Data(#"{"number":7,"state":"OPEN","isDraft":true,"statusCheckRollup":[]}"#.utf8), url: "https://github.com/you/app/pull/7"))
    #expect(draft.state == .draft && draft.checks == nil)
    #expect(try #require(PullRequests.parse(Data(#"{"number":7,"state":"MERGED"}"#.utf8), url: "u")).state == .merged)
    #expect(PullRequest.number(in: "https://github.com/you/app/pull/412/files") == 412)
}

@MainActor
@Test func ghIsAskedAtMostOnceAMinuteAndRestsWhenSignedOut() async throws {
    let pulls = PullRequests()
    let calls = Counter()
    pulls.gh = { "/usr/local/bin/gh" }
    pulls.run = { _, _ in
        await calls.add()
        return ProcessRunner.Result(status: 0, output: Data(#"{"number":1,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#.utf8))
    }
    let changes = Changes()
    pulls.changed = { changes.count += 1 }
    let url = "https://github.com/you/app/pull/1"
    let start = Date()
    #expect(pulls.pull(url, now: start) == PullRequest(url: url))
    for _ in 0..<200 where changes.count < 1 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(pulls.pull(url, now: start.addingTimeInterval(30))?.checks == .passing)
    #expect(await calls.value == 1)
    _ = pulls.pull(url, now: start.addingTimeInterval(61))
    for _ in 0..<200 where await calls.value < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await calls.value == 2)
    #expect(pulls.pull(nil) == nil && pulls.pull("https://github.com/you/app") == nil)

    let signedOut = PullRequests()
    let tries = Counter()
    signedOut.gh = { "/usr/local/bin/gh" }
    signedOut.run = { _, _ in
        await tries.add()
        return ProcessRunner.Result(status: 4, errors: Data("To get started with GitHub CLI, please run:  gh auth login".utf8))
    }
    _ = signedOut.pull(url, now: start)
    for _ in 0..<200 where await tries.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
    // swiftlint:disable:next sleep_as_sync_in_tests -- proving that nothing more runs needs the time to pass.
    try await Task.sleep(for: .milliseconds(50))
    _ = signedOut.pull(url, now: Date().addingTimeInterval(120))
    #expect(await tries.value == 1)
    #expect(signedOut.pull(url)?.url == url)
}

@MainActor private final class Changes {
    var count = 0
}

private actor Counter {
    var value = 0
    func add() { value += 1 }
}
