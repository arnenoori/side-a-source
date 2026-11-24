import Foundation
import SideADaemonKit

// sidead [--host 127.0.0.1] [--port 47800]
// Phase 0 spike: serves GET /v1/hello over TLS 1.3 with a key made at start-up. Prints the pin a client needs.
var host = "127.0.0.1"
var port = 47800
var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    switch flag {
    case "--host": host = arguments.popFirst() ?? host
    case "--port": port = arguments.popFirst().flatMap { Int($0) } ?? port
    default:
        FileHandle.standardError.write(Data("usage: sidead [--host ADDRESS] [--port PORT]\n".utf8))
        exit(2)
    }
}

let identity = try DaemonIdentity.generate()
let server = try await DaemonServer.start(identity: identity, host: host, port: port,
                                          router: DaemonRoutes.router(identity: identity, host: host))
FileHandle.standardOutput.write(Data(("sidead \(DaemonRoutes.version) listening on https://\(host):\(server.port) key \(identity.keyID) fp \(identity.spkiHash)\n").utf8))

// Runs until the process is stopped; systemd's SIGTERM ends it without ceremony in the spike.
try await Task.sleep(for: .seconds(Int.max / 2))
