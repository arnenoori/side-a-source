import Crypto
import Foundation
import SideACore
import SideAProtocol

/// The routes the spike serves. Everything else the Mac serves moves here in phase 2, behind the same `HTTPRequest`.
public enum DaemonRoutes {
    public static let version = "0.0.0-phase0"

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// `GET /v1/hello`, built from the protocol package. `MacInfo` is the host's record on the wire, as it is today:
    /// the id is a hash of the machine, so the machine id itself never leaves, and a daemon lists no capabilities
    /// beyond the ones it serves (none yet), which the phone treats as "hidden".
    public static func hello(identity: DaemonIdentity, host: String, port: Int, epoch: String, now: Date = Date()) -> Hello {
        Hello(app: version, build: 0, mac: MacInfo(id: machineID(), name: ProcessInfo.processInfo.hostName), capabilities: [],
              minClientBuild: RemotePolicy.minClientBuild, epoch: epoch, serverTime: now.timeIntervalSince1970,
              endpoints: Endpoints(tailnet: "\(host):\(port)"), keyID: identity.keyID)
    }

    public static func router(identity: DaemonIdentity, host: String) -> DaemonServer.Router {
        let epoch = UUID().uuidString
        return { request, connection in
            guard request.method == "GET", request.path == ["v1", "hello"] else {
                return HTTPResponse.json(404, Data(#"{"error":{"code":"not_found","message":"No such route."}}"#.utf8))
            }
            let body = (try? encoder.encode(hello(identity: identity, host: host, port: connection.localPort, epoch: epoch))) ?? Data()
            return HTTPResponse.json(200, body)
        }
    }

    /// A stable id for this machine: the first 8 bytes of the SHA-256 of `/etc/machine-id`, else of the host name, in hex.
    static func machineID() -> String {
        let seed = (try? String(contentsOfFile: "/etc/machine-id", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = seed.flatMap { $0.isEmpty ? nil : $0 } ?? ProcessInfo.processInfo.hostName
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
