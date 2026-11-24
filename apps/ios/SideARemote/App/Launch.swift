import Darwin
import Foundation
import os
import SideARemoteShared

enum Launch {
    static let signposter = OSSignposter(subsystem: RemoteLog.subsystem, category: .pointsOfInterest)
    private static let marked = OSAllocatedUnfairLock(initialState: Set<String>())

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

    static func mark(_ milestone: StaticString, _ detail: String = "") {
        let name = "\(milestone)"
        guard marked.withLock({ $0.insert(name).inserted }) else { return }
        signposter.emitEvent(milestone)
        RemoteLog.log(.app, "launch: \(name) at \(elapsed) ms" + (detail.isEmpty ? "" : " (\(detail))"))
    }
}
