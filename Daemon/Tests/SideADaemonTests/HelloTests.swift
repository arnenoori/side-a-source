import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import SideAProtocol
import Testing
@testable import SideADaemonKit

/// A TLS client that trusts one key and nothing else, the way the phone does: it ignores the certificate chain and the
/// host name and checks that the server's SPKI hash is the pinned one.
struct PinnedClient {
    struct Answer { var status: Int; var headers: String; var body: Data }
    struct Refused: Error, Equatable { let reason: String }

    let pin: String
    var maximumTLSVersion: TLSVersion?

    func get(_ path: String, port: Int, extra: String = "") async throws -> Answer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let answer = try await get(path, port: port, extra: extra, on: group)
            try await group.shutdownGracefully()
            return answer
        } catch {
            // swiftlint:disable:next swallowed_try -- the test's own error is the one reported.
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private func get(_ path: String, port: Int, extra: String, on group: MultiThreadedEventLoopGroup) async throws -> Answer {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .noHostnameVerification
        configuration.minimumTLSVersion = .tlsv12
        if let maximumTLSVersion { configuration.maximumTLSVersion = maximumTLSVersion }
        let context = try NIOSSLContext(configuration: configuration)
        let pin = pin
        let done = group.next().makePromise(of: Data.self)
        let channel = try await ClientBootstrap(group: group).channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let tls = try NIOSSLClientHandler(context: context, serverHostname: nil) { chain, promise in
                    guard let leaf = chain.first, let key = try? leaf.extractPublicKey().toSPKIBytes() else { return promise.succeed(.failed) }
                    let hash = Data(SHA256.hash(data: key)).base64EncodedString()
                        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                    promise.succeed(hash == pin ? .certificateVerified : .failed)
                }
                try channel.pipeline.syncOperations.addHandler(tls)
                try channel.pipeline.syncOperations.addHandler(Collect(done: done))
            }
        }.connect(host: "127.0.0.1", port: port).get()
        var request = channel.allocator.buffer(capacity: 128)
        request.writeString("GET \(path) HTTP/1.1\r\nHost: sidea\r\nConnection: close\r\n\(extra)\r\n")
        try await channel.writeAndFlush(request).get()
        let raw = try await done.futureResult.get()
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else { throw Refused(reason: "no head") }
        let head = String(decoding: raw[..<split.lowerBound], as: UTF8.self)
        let status = head.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        return Answer(status: status, headers: head, body: Data(raw[split.upperBound...]))
    }

    final class Collect: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        private var data = Data()
        private let done: EventLoopPromise<Data>
        init(done: EventLoopPromise<Data>) { self.done = done }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            self.data.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        }
        func channelInactive(context: ChannelHandlerContext) { done.succeed(data) }
        func errorCaught(context: ChannelHandlerContext, error: any Error) { done.fail(error); context.close(promise: nil) }
    }
}

func withServer<T>(_ body: (DaemonServer, DaemonIdentity) async throws -> T) async throws -> T {
    let identity = try DaemonIdentity.generate()
    let server = try await DaemonServer.start(identity: identity, router: DaemonRoutes.router(identity: identity, host: "127.0.0.1"))
    do {
        let result = try await body(server, identity)
        try await server.stop()
        return result
    } catch {
        // swiftlint:disable:next swallowed_try -- the test's own error is the one reported.
        try? await server.stop()
        throw error
    }
}

@Test func helloOverPinnedTLS13DecodesAsTheProtocolsHello() async throws {
    try await withServer { server, identity in
        #expect(server.port > 0)
        let answer = try await PinnedClient(pin: identity.spkiHash).get("/v1/hello", port: server.port)
        #expect(answer.status == 200)
        #expect(answer.headers.lowercased().contains("content-type: application/json"))
        let hello = try JSONDecoder().decode(Hello.self, from: answer.body)
        #expect(hello.protocolVersion == ProtocolVersion.current)
        #expect(hello.keyID == identity.keyID && hello.keyID.count == 16)
        #expect(hello.endpoints.tailnet == "127.0.0.1:\(server.port)")
        #expect(hello.mac.id.count == 16 && !hello.mac.name.isEmpty)
        #expect(hello.capabilities.isEmpty && hello.remoteOn && hello.paired == nil)
        #expect(abs(hello.serverTime - Date().timeIntervalSince1970) < 30)
    }
}

@Test func aClientPinningAnotherKeyIsRefused() async throws {
    try await withServer { server, _ in
        let other = try DaemonIdentity.generate()
        await #expect(throws: (any Error).self) { _ = try await PinnedClient(pin: other.spkiHash).get("/v1/hello", port: server.port) }
    }
}

@Test func tls12IsRefused() async throws {
    try await withServer { server, identity in
        await #expect(throws: (any Error).self) {
            _ = try await PinnedClient(pin: identity.spkiHash, maximumTLSVersion: .tlsv12).get("/v1/hello", port: server.port)
        }
    }
}

@Test func otherRoutesAndMalformedRequestsAreRefusedLikeOnTheMac() async throws {
    try await withServer { server, identity in
        let client = PinnedClient(pin: identity.spkiHash)
        let missing = try await client.get("/v1/sessions", port: server.port)
        let chunked = try await client.get("/v1/hello", port: server.port, extra: "Transfer-Encoding: chunked\r\n")
        let climbing = try await client.get("/v1/../hello", port: server.port)
        #expect(missing.status == 404)
        #expect(chunked.status == 411)
        #expect(climbing.status == 400)
    }
}

@Test func theKeyIDMatchesTheCertificatesKey() throws {
    let identity = try DaemonIdentity.generate()
    let certificate = try NIOSSLCertificate(bytes: identity.certificate, format: .der)
    let spki = try certificate.extractPublicKey().toSPKIBytes()
    #expect(Data(SHA256.hash(data: spki)).prefix(8).map { String(format: "%02x", $0) }.joined() == identity.keyID)
}
