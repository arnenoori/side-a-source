import Foundation
import SideACore

/// How alerts and dismissals reach the relay: one at a time per notification (a dismiss never overtakes the alert it
/// follows, and a second alert never overtakes the first), and tried again, a few times, when the relay or APNs couldn't
/// take them. Nothing about a session is logged: a line names the kind of push, a short id, the phone and what happened.
@MainActor
final class PushDelivery {
    /// The waits before each retry, so a push that can't get through stops trying after the last one.
    var delays: [Duration] = [.seconds(2), .seconds(8), .seconds(30)]
    /// Longest the relay's own `Retry-After` is honoured for.
    nonisolated static let longestWait: Double = 60
    /// Tests stand in for the relay here.
    var transmit: ((RelayClient.Send) async throws -> [RelayClient.Result])?
    var relay: () -> RelayClient? = { nil }
    var canSend: Bool { transmit != nil || relay() != nil }
    var noted: (_ device: String, _ result: String) -> Void = { _, _ in }
    var failed: (Error) -> Void = { _ in }
    var log: (String) -> Void = { RemoteLog.shared($0) }

    private var tails: [String: (ticket: Int, task: Task<Void, Never>)] = [:]
    private var issued = 0
    /// Per collapse id, the phones an alert gave up on: they never showed it, so nothing follows it there.
    private var gaveUp: [String: Set<String>] = [:]

    func line(_ kind: String, _ collapse: String, device: String?, _ decision: String, _ reason: String, relay: String? = nil, attempts: Int? = nil) {
        var parts = ["push kind=\(kind)", "id=\(collapse.prefix(8))"]
        if let device { parts.append("device=\(device.prefix(6))") }
        parts += ["decision=\(decision)", "reason=\(reason)"]
        if let relay { parts.append("relay=\(relay)") }
        if let attempts, attempts > 1 { parts.append("attempts=\(attempts)") }
        log(parts.joined(separator: " "))
    }

    /// Runs `work` after everything already queued for `collapse`.
    func enqueue(_ collapse: String, _ work: @escaping @MainActor () async -> Void) {
        let before = tails[collapse]?.task
        issued += 1
        let ticket = issued
        tails[collapse] = (ticket, Task { @MainActor [weak self] in
            await before?.value
            await work()
            if self?.tails[collapse]?.ticket == ticket { self?.tails[collapse] = nil }
        })
    }

    /// An alert. `alive` turns false once what it announces is settled, and a retry then doesn't go. `follows`: this
    /// replaces a notification already sent, so it skips phones that never got that one.
    func alert(_ body: RelayClient.Send, kind: String, reason: String, follows: Bool = false, alive: @escaping () -> Bool,
               done: @escaping ([String: String]) -> Void) {
        enqueue(body.collapseId) { [self] in
            var body = body
            if follows {
                let missed = gaveUp[body.collapseId] ?? []
                for device in body.devices where missed.contains(device) {
                    line(kind, body.collapseId, device: device, "skipped", "never-showed-the-first")
                }
                let live = body.devices.filter { !missed.contains($0) }
                guard !live.isEmpty else { return }
                body = body.restricted(to: live)
            }
            guard alive() else {
                for device in body.devices {
                    line(kind, body.collapseId, device: device, "skipped", "settled-before-sent")
                    gaveUp[body.collapseId, default: []].insert(device)
                }
                done(Dictionary(uniqueKeysWithValues: body.devices.map { ($0, "settled") }))
                return
            }
            let (results, attempts) = await deliver(body, alive: alive)
            for (device, result) in results.sorted(by: { $0.key < $1.key }) {
                line(kind, body.collapseId, device: device, Self.decision(result), reason, relay: result, attempts: attempts)
                if result != "ok" { gaveUp[body.collapseId, default: []].insert(device) }
            }
            if gaveUp.count > PushDismissals.kept { gaveUp.removeAll() }
            done(results)
        }
    }

    func dismiss(_ body: RelayClient.Send, reason: String) {
        enqueue(body.collapseId) { [self] in
            let missed = gaveUp.removeValue(forKey: body.collapseId) ?? []
            for device in body.devices where missed.contains(device) {
                line("dismiss", body.collapseId, device: device, "skipped", "never-showed-the-alert")
            }
            let live = body.devices.filter { !missed.contains($0) }
            guard !live.isEmpty else { return }
            let (results, attempts) = await deliver(body.restricted(to: live), alive: { true })
            for (device, result) in results.sorted(by: { $0.key < $1.key }) {
                line("dismiss", body.collapseId, device: device, Self.decision(result), reason, relay: result, attempts: attempts)
            }
        }
    }

    /// Each phone's last word, and how many tries it took.
    private func deliver(_ first: RelayClient.Send, alive: () -> Bool) async -> (results: [String: String], attempts: Int) {
        var body = first
        var final: [String: String] = [:]
        var attempt = 1
        while true {
            var again: [String] = []
            var wait = 0.0
            do {
                let replies = try await send(body)
                for reply in replies {
                    noted(reply.device, reply.result)
                    if reply.result == "retry" { again.append(reply.device); wait = max(wait, reply.after ?? 0) } else { final[reply.device] = reply.result }
                }
                for device in body.devices where final[device] == nil && !again.contains(device) { final[device] = "no-answer" }
            } catch {
                failed(error)
                guard let failure = error as? RelayClient.Failure, Self.retryable(failure) else {
                    for device in body.devices { final[device] = "failed" }
                    return (final, attempt)
                }
                again = body.devices
                wait = failure.retryAfter ?? 0
            }
            guard !again.isEmpty else { return (final, attempt) }
            guard attempt <= delays.count, alive() else {
                for device in again { final[device] = alive() ? "gave-up" : "settled" }
                return (final, attempt)
            }
            try? await Task.sleep(for: max(delays[attempt - 1], .seconds(min(wait, Self.longestWait))))
            guard alive() else {
                for device in again { final[device] = "settled" }
                return (final, attempt)
            }
            attempt += 1
            body = body.restricted(to: again)
        }
    }

    private func send(_ body: RelayClient.Send) async throws -> [RelayClient.Result] {
        if let transmit { return try await transmit(body) }
        guard let relay = relay() else { throw RelayClient.Failure.unreachable }
        return try await relay.send(body)
    }

    nonisolated static func decision(_ result: String) -> String { result == "ok" ? "sent" : result == "settled" ? "dropped" : "failed" }

    /// The relay couldn't be reached, was busy, or failed: worth another go. A 4xx says the request itself is wrong.
    nonisolated static func retryable(_ failure: RelayClient.Failure) -> Bool {
        failure.status == 0 || failure.status == 429 || failure.status >= 500
    }
}

extension RelayClient.Send {
    func restricted(to ids: [String]) -> RelayClient.Send {
        RelayClient.Send(devices: ids, kind: kind, category: category, collapseId: collapseId, priority: priority, expiresIn: expiresIn,
                         sound: sound, level: level, sealed: sealed.map { $0.filter { ids.contains($0.key) } })
    }
}
