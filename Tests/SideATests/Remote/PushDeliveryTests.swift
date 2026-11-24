import Foundation
import SideACore
import SideAProtocol
import SideAProtocolFixtures
import Testing
@testable import SideA

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let away = UserPresence(idle: 120, locked: false)
private let atMac = UserPresence(idle: 5, locked: false)

/// A stand-in relay: records every send, can hold them, and fails on cue.
@MainActor private final class Wire {
    private(set) var sends: [RelayClient.Send] = []
    var failures: [Error] = []
    var reply: (RelayClient.Send) -> [RelayClient.Result] = { body in body.devices.map { RelayClient.Result(device: $0, result: "ok") } }
    var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func call(_ body: RelayClient.Send) async throws -> [RelayClient.Result] {
        sends.append(body)
        if held { await withCheckedContinuation { waiting.append($0) } }
        if !failures.isEmpty { throw failures.removeFirst() }
        return reply(body)
    }

    func release() {
        held = false
        for waiter in waiting { waiter.resume() }
        waiting = []
    }

    var kinds: [String] { sends.map(\.kind) }
}

@MainActor private final class Rig {
    let remote = RemoteController(store: AccountStore(demo: true), keychain: .inMemory(), addresses: ["127.0.0.1"], port: 1_025)
    let wire = Wire()
    var lines: [String] = []
    var now = start
    var presence = away
    var sealed: [(payload: PushPayload, category: PushCategory)] = []

    init(prefs: NotificationPrefs = NotificationPrefs(), phones: [String] = ["p1"], file: URL? = nil) throws {
        for id in phones {
            try remote.devices.add(RemoteDevice(id: id, name: id, model: "iPhone", system: "iOS", app: "1.0", build: 1, hash: Data(count: 32),
                                                secretHash: "s", created: 0), replacing: nil)
            _ = try remote.devices.update(id) {
                $0.pushKey = Data(repeating: 7, count: 32)
                $0.pushKeyID = Data([1, 2, 3, 4])
                $0.push = PushRegistration(apnsToken: "aa", activityTokens: [:], prefs: prefs)
            }
        }
        let push = remote.push
        push.outstandingURL = file
        push.delivery.transmit = { [wire] body in try await wire.call(body) }
        push.delivery.delays = Array(repeating: .milliseconds(1), count: 3)
        push.delivery.log = { [weak self] in self?.lines.append($0) }
        push.presence = { [weak self] in self?.presence ?? away }
        push.clock = { [weak self] in self?.now ?? start }
        push.sealing = { [weak self] payload, category, _, _ in self?.sealed.append((payload, category)) }
    }

    func request() throws -> RemoteRequest {
        let request = try JSONDecoder().decode(RemoteRequest.self, from: Fixtures.data("RemoteRequest.bash"))
        remote.push.request(request)
        now += 11
        remote.push.tick()
        return request
    }

    func watching(_ session: String?, foreground: Bool = true) {
        remote.push.presenceOf = { [weak self] _ in EventHub.Presence(foreground: foreground, viewing: session, at: self?.now ?? start) }
    }

    func logged(_ parts: String...) -> Bool { lines.contains { line in parts.allSatisfy(line.contains) } }
}

private let sessionOfTheFixture = "8c1d2f3e-4a5b-4c6d-8e7f-9a0b1c2d3e4f"

struct PushWatchingRuleTests {
    private func holds(_ prefs: NotificationPrefs? = NotificationPrefs(), foreground: Bool = true, viewing: String? = nil, age: TimeInterval = 5,
                       session: String? = "s1") -> Bool {
        let now = Date()
        return PushWatching.holds(prefs: prefs, foreground: foreground, viewing: viewing, at: now - age, now: now, session: session)
    }

    @Test func onlyAPhoneOpenOnTheSessionHoldsItsPush() {
        #expect(holds(viewing: "s1"))
        #expect(!holds(viewing: "s2"), "another session is open")
        #expect(!holds(viewing: nil), "the list is showing")
        #expect(!holds(foreground: false, viewing: "s1"))
    }

    @Test func aPushAboutNoOneSessionIsHeldByAnyPhoneInFront() {
        #expect(holds(viewing: nil, session: nil))
        #expect(!holds(foreground: false, session: nil))
    }

    @Test func theSettingAndTheLeaseDecide() {
        #expect(!holds(NotificationPrefs(suppressWhileWatching: false), viewing: "s1"))
        #expect(holds(nil, viewing: "s1"), "a phone that never registered prefs is treated as asking for quiet")
        #expect(holds(viewing: "s1", age: 40))
        #expect(!holds(viewing: "s1", age: 41), "a presence this old may be a suspended phone")
    }
}

@MainActor struct PushWatchingFlowTests {
    @Test func aRequestOnTheWatchedSessionWaitsAndGoesOnceThePhoneLeaves() async throws {
        let rig = try Rig()
        rig.watching(sessionOfTheFixture)
        let request = try rig.request()
        await settle()
        #expect(rig.wire.sends.isEmpty)
        #expect(rig.logged("kind=request", "device=p1", "decision=suppressed", "reason=watching"))

        rig.watching(sessionOfTheFixture, foreground: false)
        rig.remote.push.watchingChanged()
        #expect(await eventually { rig.wire.sends.count == 1 })
        #expect(rig.wire.sends.first?.devices == ["p1"] && rig.wire.sends.first?.kind == "alert")
        #expect(await eventually { rig.logged("decision=sent", "reason=stopped-watching", "relay=ok") })

        rig.remote.push.watchingChanged()
        await settle()
        #expect(rig.wire.sends.count == 1, "once")
        rig.remote.push.dismiss(request.id)
        #expect(await eventually { rig.wire.kinds == ["alert", "dismiss"] })
    }

    @Test func aRequestAnsweredWhileWatchedIsNeverPushed() async throws {
        let rig = try Rig()
        rig.watching(sessionOfTheFixture)
        let request = try rig.request()
        rig.remote.push.dismiss(request.id, answeredBy: "p1")
        rig.watching(nil, foreground: false)
        rig.remote.push.watchingChanged()
        await settle()
        #expect(rig.wire.sends.isEmpty)
    }

    @Test func aPhoneOnAnotherSessionOrWithTheSettingOffGetsItAtOnce() async throws {
        let other = try Rig()
        other.watching("some-other-session")
        _ = try other.request()
        #expect(await eventually { other.wire.sends.count == 1 })

        let off = try Rig(prefs: NotificationPrefs(suppressWhileWatching: false))
        off.watching(sessionOfTheFixture)
        _ = try off.request()
        #expect(await eventually { off.wire.sends.count == 1 })
    }

    @Test func onlyTheWatchingPhoneWaits() async throws {
        let rig = try Rig(phones: ["p1", "p2"])
        rig.remote.push.presenceOf = { [weak rig] device in
            device == "p1" ? EventHub.Presence(foreground: true, viewing: sessionOfTheFixture, at: rig?.now ?? start) : nil
        }
        _ = try rig.request()
        #expect(await eventually { rig.wire.sends.count == 1 })
        #expect(rig.wire.sends.first?.devices == ["p2"])
        rig.remote.push.presenceOf = { _ in nil }
        rig.remote.push.watchingChanged()
        #expect(await eventually { rig.wire.sends.count == 2 })
        #expect(rig.wire.sends.last?.devices == ["p1"])
    }
}

@MainActor struct PushOrderAndRetryTests {
    @Test func aDismissNeverOvertakesItsAlert() async throws {
        let rig = try Rig()
        rig.wire.held = true
        let request = try rig.request()
        #expect(await eventually { rig.wire.sends.count == 1 })
        rig.remote.push.dismiss(request.id, answeredBy: nil)
        await settle()
        #expect(rig.wire.kinds == ["alert"], "the dismiss waits behind the alert still in flight")
        rig.wire.release()
        #expect(await eventually { rig.wire.kinds == ["alert", "dismiss"] })
    }

    @Test func aFailedSendIsTriedAgainUntilItTakes() async throws {
        let rig = try Rig()
        rig.wire.failures = [RelayClient.Failure.unreachable, RelayClient.Failure(status: 503, code: "x", message: ""),
                             RelayClient.Failure(status: 429, code: "rate_limited", message: "", retryAfter: 0)]
        _ = try rig.request()
        #expect(await eventually { rig.logged("decision=sent", "relay=ok", "attempts=4") })
        #expect(rig.wire.sends.count == 4)
    }

    @Test func aPhoneAPNsAskedToRetryIsTriedAgainAloneButOneThatIsGoneIsNot() async throws {
        let rig = try Rig(phones: ["p1", "p2", "p3"])
        var calls = 0
        rig.wire.reply = { body in
            calls += 1
            return body.devices.map { device in
                switch device {
                case "p1": RelayClient.Result(device: device, result: calls == 1 ? "retry" : "ok", after: 0)
                case "p2": RelayClient.Result(device: device, result: "gone")
                default: RelayClient.Result(device: device, result: "ok")
                }
            }
        }
        _ = try rig.request()
        #expect(await eventually { rig.wire.sends.count == 2 })
        #expect(rig.wire.sends.last?.devices == ["p1"])
        #expect(await eventually { rig.logged("device=p2", "decision=failed", "relay=gone") && rig.logged("device=p1", "decision=sent", "attempts=2") })
    }

    @Test func aRefusalTheRelayMeansIsNotRetriedAndTheTriesAreBounded() async throws {
        let refused = try Rig()
        refused.wire.failures = [RelayClient.Failure(status: 400, code: "bad_request", message: "")]
        _ = try refused.request()
        #expect(await eventually { refused.logged("decision=failed") })
        #expect(refused.wire.sends.count == 1)

        let down = try Rig()
        down.wire.failures = Array(repeating: RelayClient.Failure.unreachable, count: 20)
        _ = try down.request()
        #expect(await eventually { down.logged("decision=failed", "relay=gave-up") })
        #expect(down.wire.sends.count == 4, "the first try and three retries")
    }

    @Test func aRequestAnsweredBetweenTriesIsNotSentAgain() async throws {
        let rig = try Rig()
        let id = try JSONDecoder().decode(RemoteRequest.self, from: Fixtures.data("RemoteRequest.bash")).id
        rig.wire.failures = Array(repeating: RelayClient.Failure.unreachable, count: 20)
        rig.delivery(retryAfter: .milliseconds(200))
        _ = try rig.request()
        #expect(await eventually { rig.wire.sends.count == 1 })
        rig.remote.push.dismiss(id, answeredBy: "p1")
        #expect(await eventually { rig.logged("decision=dropped") })
        #expect(rig.wire.sends.count == 1, "no second alert, and no dismiss for a notification that never showed")
    }
}

private extension Rig {
    func delivery(retryAfter: Duration) { remote.push.delivery.delays = Array(repeating: retryAfter, count: 3) }
}

@MainActor struct PushOutcomeTests {
    @Test func aRequestNobodyAnsweredReplacesItsNotificationInsteadOfSayingAnswered() async throws {
        let rig = try Rig()
        let request = try rig.request()
        #expect(await eventually { rig.logged("decision=sent") })
        #expect(RemotePush.unanswered(.handedBack) != nil && RemotePush.unanswered(.gone) != nil && RemotePush.unanswered(.finished) != nil)
        #expect(RemotePush.unanswered(.mac) == nil && RemotePush.unanswered(.terminal) == nil && RemotePush.unanswered(.remote(device: "p1", name: "x")) == nil)

        rig.remote.push.withdrawn(request, why: RemotePush.unanswered(.handedBack) ?? "")
        #expect(await eventually { rig.wire.sends.count == 2 })
        #expect(rig.wire.kinds == ["alert", "alert"], "no relay dismiss: it would say Answered")
        #expect(rig.wire.sends[1].category == PushCategory.health.rawValue && rig.wire.sends[1].collapseId == rig.wire.sends[0].collapseId)
        #expect(rig.sealed.last?.payload.body == "Handed back to the terminal" && rig.sealed.last?.category == .health)
    }

    @Test func aReadyRowThatExpiredLeavesItsNotificationButAReplyClearsIt() async throws {
        let rig = try Rig()
        let turn = FinishedSession(sessionID: "a", turnID: "turn-a", title: "a", summary: "Done.", at: 0, canFollowUp: true)
        rig.remote.push.finished(turn, ran: 300)
        #expect(await eventually { rig.wire.sends.count == 1 })
        rig.remote.push.finishedResolved("turn-a", reason: .expired)
        await settle()
        #expect(rig.wire.kinds == ["alert"])
        #expect(rig.logged("decision=skipped", "reason=nobody-answered"))

        let again = try Rig()
        again.remote.push.finished(turn, ran: 300)
        #expect(await eventually { again.wire.sends.count == 1 })
        again.remote.push.finishedResolved("turn-a", reason: .replied)
        #expect(await eventually { again.wire.kinds == ["alert", "dismiss"] })
    }

    @Test func theLimitPushNamesThePercentage() throws {
        let account = try JSONDecoder().decode(RemoteAccount.self, from: Fixtures.data("RemoteAccount.claude"))
        let window = UsageWindow(id: "five-hour", label: "5h", percent: 91.6, resetsAt: nil)
        let payload = RemotePushPayload.limit(account, window: window, mac: "m", now: 1)
        #expect(payload.title == "\(account.name) is at 92%" && payload.percent == 92)
    }

    @Test func aDroppedReplyAsksForActiveSoTheRelayIsWhatMakesItQuiet() async throws {
        let rig = try Rig()
        rig.remote.push.queuedDropped(session: "s1", title: "app", text: "go on")
        #expect(await eventually { rig.wire.sends.count == 1 })
        #expect(rig.wire.sends.first?.level == "active" && rig.wire.sends.first?.category == PushCategory.health.rawValue)
    }
}

@MainActor struct PushRelaunchTests {
    private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pending-pushes-\(UUID().uuidString).json") }

    @Test func aNotificationLeftByARelaunchIsReplacedAndTheRecordIsKeptOnlyWhileItShows() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Rig(file: url)
        let request = try before.request()
        #expect(await eventually { FileManager.default.fileExists(atPath: url.path) })

        let after = try Rig(file: url)
        after.remote.push.sweepStaleAlerts()
        #expect(await eventually { after.wire.sends.count == 1 })
        #expect(after.wire.sends.first?.category == PushCategory.health.rawValue && after.wire.sends.first?.devices == ["p1"])
        #expect(after.wire.sends.first?.collapseId == RemotePush.collapse(request.id))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        after.remote.push.sweepStaleAlerts()
        await settle()
        #expect(after.wire.sends.count == 1, "once per launch")

        let answered = try Rig(file: url)
        let second = try answered.request()
        #expect(await eventually { FileManager.default.fileExists(atPath: url.path) })
        answered.remote.push.dismiss(second.id, answeredBy: nil)
        #expect(await eventually { !FileManager.default.fileExists(atPath: url.path) })
    }

    @Test func aRequestStillWaitingIsNotReplacedBySweeping() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let rig = try Rig(file: url)
        let request = try rig.request()
        #expect(await eventually { FileManager.default.fileExists(atPath: url.path) })
        rig.remote.push.swept = false
        rig.remote.push.sweepStaleAlerts()
        await settle()
        #expect(rig.wire.sends.count == 1 && rig.wire.sends.first?.collapseId == RemotePush.collapse(request.id))
    }
}

@MainActor struct PushDecisionLogTests {
    @Test func everyDecisionIsOneLineWithoutSecretsOrWords() async throws {
        let rig = try Rig(phones: ["p1", "p2"])
        _ = try rig.remote.devices.update("p2") { $0.push = PushRegistration(apnsToken: "bb-secret-token", activityTokens: [:], prefs: NotificationPrefs(requests: false)) }
        rig.presence = atMac
        let request = try JSONDecoder().decode(RemoteRequest.self, from: Fixtures.data("RemoteRequest.bash"))
        rig.remote.push.request(request)
        #expect(rig.logged("kind=request", "decision=held", "reason=at-mac"))
        rig.presence = away
        rig.now += 100
        rig.remote.push.tick()
        #expect(await eventually { rig.logged("kind=request", "device=p1", "decision=sent", "reason=user-away", "relay=ok") })
        #expect(rig.logged("kind=request", "device=p2", "decision=skipped", "reason=setting-off"))

        rig.remote.push.dismiss(request.id)
        #expect(await eventually { rig.logged("kind=dismiss", "decision=sent", "relay=ok") })
        for line in rig.lines {
            #expect(line.hasPrefix("push kind="))
            #expect(!line.contains("npm test") && !line.contains("Run a command") && !line.contains("secret") && !line.contains("\n"))
        }
    }

    @Test func aHeldRequestAnsweredFirstIsLoggedAsSuch() throws {
        let rig = try Rig()
        rig.presence = atMac
        let request = try JSONDecoder().decode(RemoteRequest.self, from: Fixtures.data("RemoteRequest.bash"))
        rig.remote.push.request(request)
        rig.remote.push.dismiss(request.id)
        #expect(rig.logged("decision=skipped", "reason=settled-before-sent"))
    }
}
