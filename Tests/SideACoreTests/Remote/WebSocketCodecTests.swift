import Foundation
@testable import SideACore
import Testing

/// A client frame, masked as a client must.
private func clientFrame(_ opcode: UInt8, _ payload: Data, fin: Bool = true, mask: [UInt8] = [1, 2, 3, 4]) -> Data {
    var out = Data([(fin ? 0x80 : 0) | opcode])
    if payload.count < 126 { out.append(0x80 | UInt8(payload.count)) } else { out.append(0x80 | 126); out.append(UInt8(payload.count >> 8)); out.append(UInt8(payload.count & 0xFF)) }
    out.append(contentsOf: mask)
    out.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset & 3] })
    return out
}

@Test func handshakeNeedsAVersion13Upgrade() throws {
    func request(_ headers: [(String, String)], method: String = "GET") -> HTTPRequest {
        HTTPRequest(method: method, target: "/v1/ws/events", path: ["v1", "ws", "events"], query: [:], headers: HTTPHeaders(headers), body: Data())
    }
    let good: [(String, String)] = [("Connection", "keep-alive, Upgrade"), ("Upgrade", "websocket"), ("Sec-WebSocket-Version", "13"),
                                    ("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")]
    let response = try WebSocketCodec.handshake(request(good)).get()
    #expect(response.status == 101 && response.headers["Sec-WebSocket-Accept"] == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    let head = String(decoding: response.encoded(close: false), as: UTF8.self)
    #expect(!head.contains("Content-Length") && head.contains("\r\nConnection: Upgrade\r\n") && head.contains("\r\nUpgrade: websocket\r\n"))
    #expect((try? WebSocketCodec.handshake(request(Array(good.prefix(2)))).get()) == nil)
    #expect((try? WebSocketCodec.handshake(request(good.dropLast() + [("Sec-WebSocket-Key", "short")])).get()) == nil)
    #expect((try? WebSocketCodec.handshake(request(good, method: "POST")).get()) == nil)
}

@Test func framesSplitAnywhereAndFragmentsReassemble() throws {
    let bytes = clientFrame(1, Data("hel".utf8), fin: false) + clientFrame(9, Data("p".utf8)) + clientFrame(0, Data("lo".utf8))
        + clientFrame(2, Data(repeating: 7, count: 300)) + clientFrame(8, Data([0x03, 0xE8]) + Data("bye".utf8))
    let expected: [WebSocketCodec.Message] = [.ping(Data("p".utf8)), .text("hello"), .binary(Data(repeating: 7, count: 300)), .close(code: 1000, reason: "bye")]
    for cut in 0..<bytes.count {
        var parser = WebSocketCodec.Parser()
        let out = parser.feed(bytes.prefix(cut)) + parser.feed(bytes.dropFirst(cut))
        #expect(try out.map { try $0.get() } == expected)
    }
}

@Test func refusesUnmaskedOversizedAndMalformedFrames() {
    func failure(_ bytes: Data) -> UInt16? {
        var parser = WebSocketCodec.Parser()
        if case .failure(let failure)? = parser.feed(bytes).first { return failure.code }
        return nil
    }
    #expect(failure(Data([0x81, 0x01, 0x41])) == 1002)
    let tooLong = UInt64(1 << 20) + 1
    #expect(failure(Data([0x81, 0x80 | 127]) + Data((0..<8).reversed().map { UInt8(tooLong >> UInt64($0 * 8) & 0xFF) }) + Data([1, 2, 3, 4])) == 1009)
    #expect(failure(clientFrame(1, Data([0xC3, 0x28]))) == 1007)
    #expect(failure(clientFrame(9, Data(count: 2), fin: false)) == 1002)
    #expect(failure(clientFrame(0, Data("x".utf8))) == 1002)
    #expect(failure(clientFrame(3, Data())) == 1002)
    #expect(failure(clientFrame(1, Data("a".utf8), fin: false) + clientFrame(1, Data("b".utf8))) == 1002)
}

@Test func serverFramesUseTheShortestLength() {
    #expect(WebSocketCodec.frame(.text("hi")) == Data([0x81, 2, 0x68, 0x69]))
    #expect(WebSocketCodec.frame(.binary, Data(count: 300)).prefix(4) == Data([0x82, 126, 1, 44]))
    #expect(WebSocketCodec.frame(.binary, Data(count: 70_000)).prefix(10) == Data([0x82, 127, 0, 0, 0, 0, 0, 1, 0x11, 0x70]))
    #expect(WebSocketCodec.frame(.close(code: 4401, reason: "")) == Data([0x88, 2, 0x11, 0x31]))
}
