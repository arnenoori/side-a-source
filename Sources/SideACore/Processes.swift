import Darwin

/// Checked right before a quit signal, since a pid from the listing may since belong to another process.
public enum ProcessCheck {
    public static func startTime(_ pid: Int) -> Double? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }

    public static func alive(_ pid: Int) -> Bool { startTime(pid) != nil }

    /// `started` comes from ps, in whole seconds.
    public static func maySignal(pid: Int, started: Double?, own: Int = Int(getpid())) -> Bool {
        guard pid > 1, pid != own, let started, let now = startTime(pid) else { return false }
        return abs(now.rounded(.down) - started) <= 1
    }
}

/// How long a bridge run may take. A process can spend most of its time waiting for a CPU, so a limit
/// that suits a calm Mac stretches with the load instead of reading as a failure.
public enum BridgeDeadline {
    public static func seconds(_ base: Double, load: Double, cores: Int) -> Double {
        base * min(4, max(1, load / Double(max(cores, 1))))
    }

    public static func current(_ base: Double) -> Double {
        var load = [0.0]
        guard getloadavg(&load, 1) == 1 else { return base }
        return seconds(base, load: load[0], cores: sysconf(_SC_NPROCESSORS_ONLN))
    }
}
