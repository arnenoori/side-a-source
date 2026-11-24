import Foundation
import os

/// Signpost intervals around bridge calls and remote routes, for Instruments, and one persisted log line for any that
/// took a second or more, which `scripts/perf-summary.py` reads back. Names only: a bridge command's first word, a route's
/// pattern. Never arguments, ids or bodies.
enum Perf {
    static let subsystem = "com.arnenoori.sidea"
    static let signposter = OSSignposter(subsystem: subsystem, category: "perf")
    static let log = Logger(subsystem: subsystem, category: "perf")
    static let slow: Duration = .seconds(1)

    private static let open = OSAllocatedUnfairLock(initialState: [UInt64: String]())
    private static let counter = OSAllocatedUnfairLock(initialState: UInt64(0))

    static var inFlight: [String] { open.withLock { Array($0.values).sorted() } }

    static func bridge<T>(_ command: String, isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval("bridge", id: id, "\(command, privacy: .public)")
        defer { signposter.endInterval("bridge", state) }
        return try await timed("bridge \(command)", body)
    }

    static func route<T>(_ name: String, isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval("route", id: id, "\(name, privacy: .public)")
        defer { signposter.endInterval("route", state) }
        return try await timed("route \(name)", body)
    }

    private static func timed<T>(_ name: String, isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        let key = counter.withLock { $0 += 1; return $0 }
        open.withLock { $0[key] = name }
        let start = SuspendingClock.now
        defer {
            open.withLock { $0[key] = nil }
            let took = start.duration(to: .now)
            if took >= slow { log.notice("slow: \(name, privacy: .public) \(milliseconds(took), privacy: .public) ms") }
        }
        return try await body()
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// Logs when the main thread doesn't answer for 2 s or more. A utility-queue timer sends one ping at a time and waits for
/// the main queue to run it; when idle that is one tiny block a second, coalesced by the timer's leeway.
final class StallWatchdog: @unchecked Sendable {
    static let shared = StallWatchdog()
    static let threshold: Duration = .seconds(2)

    private let queue = DispatchQueue(label: "com.arnenoori.sidea.stalls", qos: .utility)
    private var timer: DispatchSourceTimer?
    // Confined to `queue`. Suspending, as in `Perf.timed`: a ping in flight while the Mac sleeps is no stall.
    private var sent: SuspendingClock.Instant?
    private var noted = false

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    private func tick() {
        let now = SuspendingClock.now
        if let sent {
            // Still blocked: say so once while it lasts, in case it never comes back.
            if !noted, sent.duration(to: now) >= Self.threshold {
                noted = true
                Perf.log.error("stall: main thread blocked for 2 s and counting, during \(Perf.inFlight.joined(separator: ", "), privacy: .public)")
            }
            return
        }
        sent = now
        let during = Perf.inFlight
        // The main queue itself is what's measured, so not a main-actor task.
        // swiftlint:disable:next dispatch_main_async_in_ui
        DispatchQueue.main.async { [self] in
            queue.async { [self] in
                if let sent {
                    let blocked = sent.duration(to: .now)
                    if blocked >= Self.threshold {
                        let what = Set(during + Perf.inFlight).sorted().joined(separator: ", ")
                        Perf.log.error("stall: main thread blocked \(Perf.milliseconds(blocked), privacy: .public) ms, during \(what.isEmpty ? "nothing measured" : what, privacy: .public)")
                    }
                }
                sent = nil
                noted = false
            }
        }
    }
}
