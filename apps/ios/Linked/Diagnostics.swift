import Foundation
import Network
import SideARemoteKit
import SideARemoteShared

/// Points the kit's diagnostics at `RemoteLog`; each process calls `start` once as it launches.
nonisolated enum Diagnostics {
    static func start() {
        KitLog.sink = { category, message in
            RemoteLog.log(RemoteLog.Category(rawValue: category.rawValue) ?? .transport, message)
        }
    }

    nonisolated(unsafe) private static var monitor: NWPathMonitor?

    /// The app's network path as it changes: status, interfaces, and whether it's expensive or constrained.
    static func watchNetwork() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let interfaces = path.availableInterfaces.map { "\($0.name) \(describe($0.type))" }.joined(separator: ", ")
            var line = "path \(path.status) via [\(interfaces)]"
            if path.isExpensive { line += " expensive" }
            if path.isConstrained { line += " constrained" }
            if path.status != .satisfied { line += " reason \(path.unsatisfiedReason)" }
            RemoteLog.log(.transport, line)
        }
        monitor.start(queue: DispatchQueue(label: "com.arnenoori.sidea.remote.path"))
        Self.monitor = monitor
    }

    private static func describe(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: "wifi"
        case .cellular: "cellular"
        case .wiredEthernet: "wired"
        case .loopback: "loopback"
        // A VPN, Tailscale's included.
        case .other: "other"
        @unknown default: "unknown"
        }
    }
}
