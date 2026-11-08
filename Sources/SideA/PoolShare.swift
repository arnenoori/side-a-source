import Foundation
import SideACore

extension SocketFront: PoolFront {}

extension PoolProxy {
    /// Also listens on `address` (this Mac's Tailscale address) for the user's other Macs, behind its own key and `admit`.
    /// Network.framework never finishes a connection on a Tailscale address (see SocketFront), so a BSD socket there
    /// hands each one to a loopback listener, which learns the real peer from SplicedPeers.
    func share(on address: String, port: UInt16 = PoolProxy.preferredPort, gate: PoolGate) async throws -> UInt16 {
        var gate = gate
        gate.peer = { SplicedPeers.shared.take($0)?.source }
        return try await share(gate: gate) { queue, inner in try SocketFront(address: address, port: port, queue: queue) { inner } }
    }
}
