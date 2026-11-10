import Foundation
import SideACore
import SideAProtocol
import SideAProtocolFixtures
import Testing
@testable import SideA

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let atMac = UserPresence(idle: 5, locked: false)
private let away = UserPresence(idle: 120, locked: false)
private let locked = UserPresence(idle: 1, locked: true)

private func turn(_ session: String, _ title: String? = nil) -> FinishedSession {
    FinishedSession(sessionID: session, turnID: "turn-" + session, title: title ?? session, summary: "Done.", at: 0, canFollowUp: true)
}

struct PushSchedulerTests {
    // MARK: At the Mac

    @Test func heldAtTheMacThenSentOnceAway() {
        var scheduler = PushScheduler()
        #expect(scheduler.add("r1", .ask(destructive: false), now: start, presence: atMac).isEmpty)
        #expect(scheduler.add("h1", .health, now: start, presence: atMac).isEmpty)
        // Past the grace, still at the Mac: nothing.
        #expect(scheduler.tick(now: start + 30, presence: UserPresence(idle: 59, locked: false)).isEmpty)
        // A minute without input.
        #expect(scheduler.tick(now: start + 90, presence: UserPresence(idle: 60, locked: false)) == [.send("r1"), .send("h1")])
        #expect(scheduler.held.isEmpty && scheduler.nextCheck(now: start + 90, presence: away) == nil)
    }

    @Test func aLockedScreenIsAwayAtOnce() {
        var scheduler = PushScheduler()
        _ = scheduler.add("h1", .health, now: start, presence: atMac)
        #expect(scheduler.tick(now: start + 1, presence: locked) == [.send("h1")])
    }

    @Test func heldThenDroppedWhenAnswered() {
        var scheduler = PushScheduler()
        _ = scheduler.add("r1", .ask(destructive: false), now: start, presence: atMac)
        _ = scheduler.add("h1", .health, now: start, presence: atMac)
        _ = scheduler.finished(turn("s1"), ran: 300, now: start, presence: atMac)
        scheduler.resolve("r1")
        scheduler.resolve("h1")
        scheduler.resolve("turn-s1")
        #expect(scheduler.tick(now: start + 120, presence: away).isEmpty)
        #expect(scheduler.nextCheck(now: start + 120, presence: away) == nil)
    }

    @Test func itWakesWhenTheUserCouldFirstBeAway() {
        var scheduler = PushScheduler()
        _ = scheduler.add("h1", .health, now: start, presence: UserPresence(idle: 20, locked: false))
        #expect(scheduler.nextCheck(now: start, presence: UserPresence(idle: 20, locked: false)) == 40)
        #expect(scheduler.nextCheck(now: start, presence: UserPresence(idle: 59.9, locked: false)) == 0.5)
    }

    // MARK: Grace

    @Test func anAskWaitsTenSecondsWhenAway() {
        var scheduler = PushScheduler()
        #expect(scheduler.add("r1", .ask(destructive: false), now: start, presence: away).isEmpty)
        #expect(scheduler.nextCheck(now: start, presence: away) == 10)
        #expect(scheduler.tick(now: start + 9.9, presence: away).isEmpty)
        #expect(scheduler.tick(now: start + 10, presence: away) == [.send("r1")])
    }

    @Test func answeredInTheGraceItNeverGoes() {
        var scheduler = PushScheduler()
        _ = scheduler.add("r1", .ask(destructive: false), now: start, presence: away)
        scheduler.resolve("r1")
        #expect(scheduler.tick(now: start + 10, presence: away).isEmpty)
    }

    @Test func aDestructiveRequestSkipsTheGraceButNotTheHold() {
        var scheduler = PushScheduler()
        #expect(scheduler.add("d1", .ask(destructive: true), now: start, presence: away) == [.send("d1")])
        #expect(scheduler.add("d2", .ask(destructive: true), now: start, presence: atMac).isEmpty)
        #expect(scheduler.tick(now: start + 1, presence: away) == [.send("d2")])
    }

    @Test func healthHasNoGrace() {
        var scheduler = PushScheduler()
        #expect(scheduler.add("h1", .health, now: start, presence: away) == [.send("h1")])
    }

    // MARK: Ready

    @Test func readyGroupsWithOneSoundAWindow() {
        var scheduler = PushScheduler()
        #expect(scheduler.finished(turn("a"), ran: 120, now: start, presence: away) == [.ready([turn("a")], quiet: false)])
        #expect(scheduler.finished(turn("b"), ran: 120, now: start + 60, presence: away) == [.ready([turn("b"), turn("a")], quiet: true)])
        #expect(scheduler.finished(turn("c"), ran: 120, now: start + 299, presence: away) == [.ready([turn("c"), turn("b"), turn("a")], quiet: true)])
        // Five minutes after the one that sounded, the next sounds again.
        #expect(scheduler.finished(turn("d"), ran: 120, now: start + 300, presence: away).first == .ready([turn("d"), turn("c"), turn("b"), turn("a")], quiet: false))
    }

    @Test func aTurnThatLeftReadyIsLeftOut() {
        var scheduler = PushScheduler()
        _ = scheduler.finished(turn("a"), ran: 120, now: start, presence: away)
        scheduler.resolve("turn-a")
        #expect(scheduler.finished(turn("b"), ran: 120, now: start + 10, presence: away) == [.ready([turn("b")], quiet: true)])
    }

    @Test func aShortTurnWaitsForTheNextPush() {
        var scheduler = PushScheduler()
        #expect(scheduler.finished(turn("a"), ran: 12, now: start, presence: away).isEmpty)
        #expect(scheduler.finished(turn("b"), ran: 29.9, now: start + 5, presence: away).isEmpty)
        #expect(scheduler.nextCheck(now: start + 5, presence: away) == nil)
        #expect(scheduler.finished(turn("c"), ran: 30, now: start + 10, presence: away) == [.ready([turn("c"), turn("b"), turn("a")], quiet: false)])
    }

    @Test func aTurnOfUnknownLengthPushes() {
        var scheduler = PushScheduler()
        #expect(scheduler.finished(turn("a"), ran: nil, now: start, presence: away) == [.ready([turn("a")], quiet: false)])
    }

    @Test func readyIsHeldAtTheMacAndDroppedIfCleared() {
        var scheduler = PushScheduler()
        #expect(scheduler.finished(turn("a"), ran: 120, now: start, presence: atMac).isEmpty)
        #expect(scheduler.finished(turn("b"), ran: 5, now: start, presence: atMac).isEmpty)
        #expect(scheduler.tick(now: start + 70, presence: away) == [.ready([turn("b"), turn("a")], quiet: false)])

        var cleared = PushScheduler()
        _ = cleared.finished(turn("a"), ran: 120, now: start, presence: atMac)
        _ = cleared.finished(turn("b"), ran: 5, now: start, presence: atMac)
        cleared.resolve("turn-a")
        // Only a short turn is left: it doesn't push on its own.
        #expect(cleared.tick(now: start + 70, presence: away).isEmpty)
    }

    @Test func aSessionsNewTurnReplacesItsOldOne() {
        var scheduler = PushScheduler()
        _ = scheduler.finished(turn("a"), ran: 120, now: start, presence: away)
        let again = FinishedSession(sessionID: "a", turnID: "turn-a2", title: "a", summary: "Again.", at: 0, canFollowUp: true)
        #expect(scheduler.finished(again, ran: 120, now: start + 60, presence: away) == [.ready([again], quiet: true)])
    }

    // MARK: Payloads, urgency, an open phone

    @Test func readyReadsAsOneSessionOrACount() {
        let one = RemotePushPayload.ready([turn("s1", "side-a")], mac: "m", now: 1, quiet: false)
        #expect(one == RemotePushPayload.finished(turn("s1", "side-a"), mac: "m", now: 1) && one.sid == "s1" && one.quiet == nil)
        let three = RemotePushPayload.ready([turn("s1", "side-a"), turn("s2", "relay"), turn("s3", "site")], mac: "m", now: 1, quiet: true)
        #expect(three.title == "3 sessions ready" && three.body == "side-a, relay, site" && three.quiet == true)
        #expect(three.sid == nil && three.turnID == nil && three.kind == .finished)
        let many = (0..<8).map { turn("s\($0)", String(repeating: "x", count: 400) + "\($0)") }
        #expect(RemotePushPayload.encoded(RemotePushPayload.ready(many, mac: "m", now: 1, quiet: true)).count <= PushPayload.budget)
    }

    @Test func rotationIsPassiveUnlessWorkStops() {
        #expect(RemotePush.rotationLevel(blocks: false) == "passive")
        #expect(RemotePush.rotationLevel(blocks: true) == "active")
    }

    /// The push side reads the presence and clock it's given, and an answer clears what it holds. No paired phone, so
    /// nothing reaches a relay.
    @MainActor @Test func remotePushHoldsWithTheGivenPresence() throws {
        let remote = RemoteController(store: AccountStore(demo: true), keychain: .inMemory(), addresses: ["127.0.0.1"], port: 1_025)
        var presence = atMac
        var now = start
        remote.push.presence = { presence }
        remote.push.clock = { now }
        let request = try JSONDecoder().decode(RemoteRequest.self, from: Fixtures.data("RemoteRequest.bash"))
        remote.push.request(request)
        #expect(remote.push.scheduler.held.map(\.id) == [request.id])
        presence = away
        now = start + 5
        remote.push.tick()
        #expect(remote.push.scheduler.held.map(\.id) == [request.id], "inside the grace")
        remote.push.dismiss(request.id)
        #expect(remote.push.scheduler.held.isEmpty)

        remote.push.finished(turn("a"), ran: 300)
        #expect(remote.push.scheduler.due.isEmpty && remote.push.scheduler.lastSound == now, "away: Ready went at once")
        remote.push.finishedResolved("turn-a")
        #expect(remote.push.scheduler.ready.isEmpty)
    }

    // MARK: Phones, as the relay would get them

    /// A demo store's Remote has no relay, so what's sealed goes nowhere; `sealing` sees it, with the phones it's for.
    @MainActor private func remote(phones: [String: Set<Capability>]) throws -> (RemoteController, () -> [Sealed]) {
        let remote = RemoteController(store: AccountStore(demo: true), keychain: .inMemory(), addresses: ["127.0.0.1"], port: 1_025)
        #expect(remote.relayURL == nil)
        for (id, capabilities) in phones.sorted(by: { $0.key < $1.key }) {
            try remote.devices.add(RemoteDevice(id: id, name: id, model: "iPhone", system: "iOS", app: "1.0", build: 1, hash: Data(count: 32),
                                                secretHash: "s", created: 0), replacing: nil)
            _ = try remote.devices.update(id) {
                $0.pushKey = Data(repeating: 7, count: 32)
                $0.pushKeyID = Data([1, 2, 3, 4])
                $0.push = PushRegistration(apnsToken: "aa", activityTokens: [:], prefs: NotificationPrefs(rotation: true))
            }
            remote.noteCapabilities(id, capabilities)
        }
        var sealed: [Sealed] = []
        remote.push.sealing = { sealed.append(Sealed(payload: $0, category: $1, collapse: $2, devices: $3)) }
        return (remote, { sealed })
    }

    struct Sealed: Equatable {
        let payload: PushPayload
        let category: PushCategory
        let collapse: String
        let devices: [String]
    }

    @MainActor @Test func readyIsGroupedOnlyForPhonesThatSaySo() throws {
        let (remote, sealed) = try remote(phones: ["new": [.events, .rotation, .readyGroups], "old": [.events, .rotation]])
        #expect(remote.devices.devices.map { $0.readyGroups == true } == [true, false])
        remote.push.presence = { away }
        remote.push.clock = { start }
        remote.push.finished(turn("a"), ran: 300)
        remote.push.finished(turn("b"), ran: 300)
        let ready = RemotePush.readyCollapse
        #expect(sealed().map(\.collapse) == [ready, RemotePush.collapse("turn-a"), ready, RemotePush.collapse("turn-b")])
        #expect(sealed().map(\.devices) == [["new"], ["old"], ["new"], ["old"]])
        // The new phone's Ready names no session once it's grouped; the old one gets each turn it can reply to.
        #expect(sealed()[2].payload.sid == nil && sealed()[2].payload.title == "2 sessions ready")
        #expect(sealed()[1].payload.sid == "a" && sealed()[3].payload.sid == "b" && sealed()[3].payload.turnID == "turn-b")
        #expect(sealed().allSatisfy { $0.category == .finished })

        // Another tick with nothing new sends an old phone nothing again.
        remote.push.finished(FinishedSession(sessionID: "c", turnID: "turn-c", title: "c", summary: "Done.", at: 0, canFollowUp: true), ran: 300)
        #expect(sealed().suffix(2).map(\.devices) == [["new"], ["old"]] && sealed().last?.payload.turnID == "turn-c")
    }

    /// Remote turned off with a request, a health warning and a turn held: none of them goes, then or later.
    @MainActor @Test func turningRemoteOffDropsWhatsHeld() async throws {
        let (remote, sealed) = try remote(phones: ["new": [.events, .readyGroups]])
        var presence = atMac
        var now = start
        remote.push.presence = { presence }
        remote.push.clock = { now }
        remote.push.request(try JSONDecoder().decode(RemoteRequest.self, from: Fixtures.data("RemoteRequest.bash")))
        remote.push.health(try JSONDecoder().decode(RemoteSession.self, from: Fixtures.data("RemoteSession.working")),
                           SessionFlag(kind: .stuck, text: "No output for 10 minutes"))
        remote.push.finished(turn("a"), ran: 300)
        #expect(remote.push.scheduler.held.count == 2 && !remote.push.scheduler.due.isEmpty)

        remote.tearDown()
        #expect(remote.push.scheduler.held.isEmpty && remote.push.scheduler.due.isEmpty && remote.push.scheduler.ready.isEmpty)
        presence = away
        now = start + 300
        remote.push.tick()
        try await Task.sleep(for: .milliseconds(100))
        #expect(sealed().isEmpty)
    }

    /// Remote turned off with a Live Activity up: the card ends at once and the minute's ticker stops; a preview's
    /// credential goes too, since the next server never hears of it.
    @MainActor @Test func turningRemoteOffEndsLiveActivitiesAndPreviews() async throws {
        let (remote, _) = try remote(phones: ["new": [.events]])
        var actions: [LiveActivities.Action] = []
        remote.push.acting = { actions += $0 }
        _ = await remote.push.register("new", PushRegistration(apnsToken: "aa", pushToStartToken: "s", activityTokens: ["a1": "t1"]))
        #expect(remote.push.ticking)
        _ = remote.previews.open(session: "s1", port: 5173, pid: 1, device: "new", host: "127.0.0.1:1025")
        #expect(remote.previews.url(session: "s1", port: 5173) != nil)

        remote.tearDown()
        #expect(actions.last == .end(device: "new", activity: "a1"))
        #expect(!remote.push.ticking)
        #expect(remote.previews.previews.isEmpty && remote.previews.url(session: "s1", port: 5173) == nil)
    }

    @Test func aNoticeWaitsOnlyForTheUserToLeave() {
        var scheduler = PushScheduler()
        #expect(scheduler.add("rotation", .notice, now: start, presence: atMac).isEmpty)
        #expect(scheduler.add("rotation", .notice, now: start + 5, presence: atMac).isEmpty)
        #expect(scheduler.held.count == 1, "the latest under its id")
        #expect(scheduler.tick(now: start + 70, presence: away) == [.send("rotation")])
        #expect(scheduler.add("limit:x", .notice, now: start + 80, presence: away) == [.send("limit:x")])
    }

    /// A limit and Autopilot's move wait while someone is at the Mac, keeping their dedupe and the latest move; a dropped
    /// queued reply doesn't wait.
    @MainActor @Test func limitAndRotationWaitWhileAtTheMac() async throws {
        let (remote, sealed) = try remote(phones: ["new": [.events, .rotation, .readyGroups]])
        var presence = atMac
        remote.push.presence = { presence }
        remote.push.clock = { start }
        let account = try JSONDecoder().decode(RemoteAccount.self, from: Fixtures.data("RemoteAccount.claude"))
        let window = try JSONDecoder().decode(UsageWindow.self, from: Fixtures.data("UsageWindow.five-hour"))
        remote.push.limit(account, window, threshold: 90)
        remote.push.limit(account, window, threshold: 90)
        remote.push.rotation(title: "Now on Work", body: nil, account: nil, resetsAt: nil, blocks: false)
        remote.push.rotation(title: "Now on Personal", body: nil, account: nil, resetsAt: nil, blocks: false)
        remote.push.queuedDropped(session: "s1", title: "side-a", text: "go on")
        #expect(sealed().map(\.category) == [.health], "only the dropped reply, at once")

        presence = away
        remote.push.tick()
        #expect(sealed().map(\.category) == [.health, .limit, .rotation])
        #expect(sealed().last?.payload.title == "Now on Personal" && sealed().last?.collapse == "rotation")
        remote.push.limit(account, window, threshold: 90)
        remote.push.tick()
        #expect(sealed().count == 3, "once per threshold")
    }

    /// A stuck warning held at the Mac, then the session's flag turns to bloated, which doesn't notify: the warning is
    /// over, so it never goes. Another notifying flag goes in its place.
    @MainActor @Test func aHeldHealthWarningEndsWhenTheFlagChanges() throws {
        let (remote, sealed) = try remote(phones: ["new": [.events, .readyGroups]])
        var presence = atMac
        remote.push.presence = { presence }
        remote.push.clock = { start }
        let session = try JSONDecoder().decode(RemoteSession.self, from: Fixtures.data("RemoteSession.working"))
        remote.push.health(session, SessionFlag(kind: .stuck, text: "No output for 10 minutes"))
        remote.push.health(session, SessionFlag(kind: .bloated, text: "Context is full"))
        #expect(remote.push.scheduler.held.isEmpty)
        presence = away
        remote.push.tick()
        #expect(sealed().isEmpty)

        presence = atMac
        remote.push.health(session, SessionFlag(kind: .stuck, text: "No output for 10 minutes"))
        remote.push.health(session, SessionFlag(kind: .loop, text: "Repeating the same step"))
        presence = away
        remote.push.tick()
        #expect(sealed().map(\.payload.body) == ["Repeating the same step"])
    }

    @Test func anOpenPhoneGetsNoPushUntilItsPresenceIsStale() {
        let now = Date()
        #expect(RemotePush.skips(EventHub.Presence(foreground: true, viewing: nil, at: now - 5), now: now))
        #expect(RemotePush.skips(EventHub.Presence(foreground: true, viewing: "s1", at: now - 40), now: now))
        #expect(!RemotePush.skips(EventHub.Presence(foreground: true, viewing: nil, at: now - 41), now: now))
        #expect(!RemotePush.skips(EventHub.Presence(foreground: false, viewing: nil, at: now), now: now))
        #expect(!RemotePush.skips(nil, now: now))
    }
}
