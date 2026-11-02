import Darwin
import Foundation
import os
import SideARemoteShared

/// Launch milestones, timed from process start: a signpost each for Instruments' Points of Interest, and a log line
/// each, so Share Logs says how long a launch took to draw, to show sessions and to go live. Each milestone counts
/// once per process.
enum Launch {
    static let signposter = OSSignposter(subsystem: RemoteLog.subsystem, category: .pointsOfInterest)
    private static let marked = OSAllocatedUnfairLock(initialState: Set<String>())

    /// When the kernel started this process, so the time before `main` counts too.
    static let started: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return .now }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    static var elapsed: Int { Int(Date.now.timeIntervalSince(started) * 1000) }

    static func ms(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private static var deferred: [() -> Void]? = []

    /// Work the first frames don't need (push registration, widgets, revocations) waits until they're drawn, or 2 s
    /// for a launch in the background that draws nothing; after that it runs at once.
    static func afterFirstFrame(_ work: @escaping () -> Void) {
        guard deferred != nil else { return work() }
        if deferred!.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { runDeferred() } }
        deferred!.append(work)
    }

    /// The first view appeared; its frames commit on this turn of the run loop, so the work goes a moment later.
    static func drawn() {
        mark("first view")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { runDeferred() }
    }

    private static func runDeferred() {
        guard let work = deferred else { return }
        deferred = nil
        mark("deferred work", "\(work.count) jobs")
        work.forEach { $0() }
    }

    /// "first frame", "sessions from cache", "live"…; `detail` goes on the log line only.
    static func mark(_ milestone: StaticString, _ detail: String = "") {
        let name = "\(milestone)"
        guard marked.withLock({ $0.insert(name).inserted }) else { return }
        signposter.emitEvent(milestone)
        RemoteLog.log(.app, "launch: \(name) at \(elapsed) ms" + (detail.isEmpty ? "" : " (\(detail))"))
    }
}
