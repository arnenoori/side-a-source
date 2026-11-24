import Foundation
import SideAProtocol

/// Whether the Mac is still there: what counts as proof, the ping that asks, and what a socket that fails the check does.
extension SyncEngine {
    /// A frame that doesn't decode still took its place in the sequence: without its seq the next frame reads as a gap,
    /// and the Mac replays this one again. Its change is lost, so the state is read afresh over REST.
    func skipped(_ data: Data) async {
        struct Sequence: Decodable { var seq: Int? }
        guard let seq = (try? JSONDecoder().decode(Sequence.self, from: data))?.seq, recon.undecodable(seq: seq) else { return }
        KitLog.log(.sync, "event \(seq) did not decode; refreshing state")
        do { try await refresh() } catch {
            KitLog.log(.sync, "refresh after event \(seq) failed: \(error)")
        }
    }

    func keepalive(_ socket: any SocketConnection, _ generation: Int) async {
        var sincePresence = 0.0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(timing.ping))
            guard !Task.isCancelled else { return }
            guard await Self.ping(socket, within: timing.pongWithin) else { return lost(socket, generation) }
            proven(socket: generation)
            sincePresence += timing.ping
            if sincePresence >= timing.presence {
                sincePresence = 0
                await sendPresence()
            }
        }
    }

    func proven(socket generation: Int? = nil) {
        guard generation == nil || generation == socketGeneration else { return }
        heardAt = now()
        heard += 1
    }

    static func ping(_ socket: any SocketConnection, within seconds: Double) async -> Bool {
        (try? await withCheckedThrowingContinuation { (done: CheckedContinuation<Bool, Error>) in
            let once = Once(done)
            let timeout = Task {
                try? await Task.sleep(for: .seconds(seconds))
                once.resume(returning: false)
            }
            Task {
                do { try await socket.sendPing(); once.resume(returning: true) } catch { once.resume(returning: false) }
                timeout.cancel()
            }
        }) ?? false
    }

    /// iOS can kill a suspended app's socket without a close, so a socket that looks live has to prove it.
    func checkSocket(away: Double) {
        guard let socket else { return }
        let generation = socketGeneration
        let silence = now() - heardAt
        if silence >= timing.macForgets { return lost(socket, generation) }
        let unproven = silence > timing.provenFor
        if unproven { set(.connecting) }
        let deadline = unproven || away >= timing.longAway ? timing.resumePong : timing.foregroundPong
        let before = heard
        probe?.cancel()
        probe = Task {
            let alive = (try? await withCheckedThrowingContinuation { (done: CheckedContinuation<Bool, Error>) in
                let once = Once(done)
                Task { once.resume(returning: await Self.ping(socket, within: deadline)) }
                Task { if await self.silentWhileMacAnswers(since: before, generation) { once.resume(returning: false) } }
            }) ?? false
            guard !Task.isCancelled, generation == socketGeneration else { return }
            guard alive || heard > before else { return lost(socket, generation) }
            proven(socket: generation)
            guard unproven, stored.connection == .connecting else { return }
            set(.live(since: liveSince))
            await sendPresence()
            Task { await self.drain() }
        }
    }

    func silentWhileMacAnswers(since before: Int, _ generation: Int) async -> Bool {
        let start = now()
        try? await Task.sleep(for: .seconds(timing.silentCheck))
        guard heard == before, generation == socketGeneration, await hostAnswers() else { return false }
        let left = timing.silentFor - (now() - start)
        if left > 0 { try? await Task.sleep(for: .seconds(left)) }
        return heard == before && generation == socketGeneration
    }

    func hostAnswers() async -> Bool {
        guard var request = try? await client.request("GET", "/v1/hello") else { return false }
        request.timeoutInterval = 3
        return (try? await client.send(request)) != nil
    }

    /// No pong: a half-open socket never ends by itself, so it's closed here and the loop connects again.
    func lost(_ socket: any SocketConnection, _ generation: Int) {
        guard generation == socketGeneration else { return }
        // A goodbye for sleep came before the pong failed: it is still why the Mac can't be reached.
        set(cause == .unknown ? .connecting : .offline(retryAt: now(), reason: "No answer from the Mac", cause: cause))
        socket.close(code: 4008, reason: "no pong")
    }
}
