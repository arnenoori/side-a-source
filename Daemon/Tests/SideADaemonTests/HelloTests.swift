import Crypto
import Foundation
import NIOSSL
import SideACore
import SideAProtocol
import Testing
@testable import SideADaemonKit

@Test func helloOverPinnedTLS13DecodesAsTheProtocolsHello() async throws {
    try await withDaemon { daemon, _ in
        let connection = try await TestConnection.open(port: daemon.port, pin: daemon.identity.spkiHash)
        let answer = try await connection.request("GET", "/v1/hello")
        #expect(answer.status == 200)
        #expect(answer.header("content-type") == "application/json")
        #expect(answer.header("x-sidea-protocol") == "1" && answer.header("x-sidea-epoch") == daemon.epoch)
        let hello = try answer.json(Hello.self)
        #expect(hello.protocolVersion == ProtocolVersion.current)
        #expect(abs(hello.serverTime - Date().timeIntervalSince1970) < 30)
        #expect(hello.remoteOn && hello.paired == nil && hello.minClientBuild != nil)
        // A stranger learns versions and the switch, not the name, id, addresses or key.
        #expect(hello.mac.id.isEmpty && hello.mac.name.isEmpty && hello.capabilities.isEmpty && hello.keyID.isEmpty)
        await connection.close()
    }
}

@Test func aPairedPhoneIsToldWhatKindOfComputerThisIs() async throws {
    try await withDaemon { daemon, _ in
        let paired = try await FakePhone().pair(with: daemon, pin: daemon.identity.spkiHash)
        let connection = try await TestConnection.open(port: daemon.port, pin: daemon.identity.spkiHash)
        let answer = try await connection.request("GET", "/v1/hello", headers: ["Authorization": "Bearer \(paired.token)"])
        let hello = try answer.json(Hello.self)
        #expect(hello.paired == true)
        #expect(hello.mac.kind == .linux && hello.mac.headless == true && hello.mac.id.count == 16)
        #expect(hello.keyID == daemon.identity.keyID && hello.keyID.count == 16)
        #expect(hello.capabilities.contains(.events))
        #expect(hello.endpoints.tailnet == "127.0.0.1:\(daemon.port)")
        // A token the daemon doesn't know reads as unpaired, which is how a revoked phone finds out.
        let wrong = try await connection.request("GET", "/v1/hello", headers: ["Authorization": "Bearer \(DeviceToken.make())"])
        #expect(try wrong.json(Hello.self).paired == false)
        await connection.close()
    }
}

@Test func aClientPinningAnotherKeyIsRefused() async throws {
    try await withDaemon { daemon, _ in
        let other = try DaemonIdentity.generate()
        await #expect(throws: (any Error).self) {
            let connection = try await TestConnection.open(port: daemon.port, pin: other.spkiHash)
            _ = try await connection.request("GET", "/v1/hello")
        }
    }
}

@Test func tls12IsRefused() async throws {
    try await withDaemon { daemon, _ in
        await #expect(throws: (any Error).self) {
            let connection = try await TestConnection.open(port: daemon.port, pin: daemon.identity.spkiHash, maximumTLSVersion: .tlsv12)
            _ = try await connection.request("GET", "/v1/hello")
        }
    }
}

@Test func malformedRequestsAndStrangersAreRefusedLikeOnTheMac() async throws {
    try await withDaemon { daemon, _ in
        let pin = daemon.identity.spkiHash
        let unpaired = try await TestConnection.open(port: daemon.port, pin: pin)
        // No token: everything but hello and pairing is 401, and the answer is the protocol's error envelope.
        let missing = try await unpaired.request("GET", "/v1/sessions")
        #expect(missing.status == 401 && missing.errorCode == "unauthorized" && missing.header("www-authenticate") == "Bearer")
        let chunked = try await TestConnection.open(port: daemon.port, pin: pin)
        let refused = try await chunked.request("GET", "/v1/hello", raw: "Transfer-Encoding: chunked\r\n")
        #expect(refused.status == 411)
        let climbing = try await TestConnection.open(port: daemon.port, pin: pin)
        #expect(try await climbing.request("GET", "/v1/../hello").status == 400)
        // A Host that isn't one of this computer's addresses is a DNS-rebinding attempt.
        let rebound = try await TestConnection.open(port: daemon.port, pin: pin)
        let host = try await rebound.request("GET", "/v1/hello", host: "evil.example")
        #expect(host.status == 421 && host.errorCode == "bad_host")
        // A browser sends Origin.
        let browser = try await TestConnection.open(port: daemon.port, pin: pin)
        #expect(try await browser.request("GET", "/v1/hello", headers: ["Origin": "https://evil.example"]).status == 403)
        for connection in [unpaired, chunked, climbing, rebound, browser] { await connection.close() }
    }
}

@Test func theKeyIDMatchesTheCertificatesKey() throws {
    let identity = try DaemonIdentity.generate()
    let certificate = try NIOSSLCertificate(bytes: identity.certificate, format: .der)
    let spki = try certificate.extractPublicKey().toSPKIBytes()
    #expect(Data(SHA256.hash(data: spki)).prefix(8).map { String(format: "%02x", $0) }.joined() == identity.keyID)
}

@Test func theIdentitySurvivesARestartSoPairedPhonesStillTrustIt() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileSecretStore(directory: directory)
    let first = try DaemonIdentity.loadOrCreate(in: store)
    let second = try DaemonIdentity.loadOrCreate(in: store)
    #expect(first.spkiHash == second.spkiHash && first.certificate == second.certificate)
    let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("tls.json").path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    // A file anyone else can read is not trusted.
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: directory.appendingPathComponent("tls.json").path)
    #expect(throws: SecretStoreError.self) { _ = try DaemonIdentity.loadOrCreate(in: store) }
}
