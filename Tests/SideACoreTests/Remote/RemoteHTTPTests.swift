import Foundation
@testable import SideACore
import Testing

private let get = Data("GET /v1/sessions/a%20b/transcript?after=4&limit=50 HTTP/1.1\r\nHost: 100.101.12.4:47800\r\nAuthorization: Bearer x\r\n\r\n".utf8)
private let post = Data("POST /v1/requests/r1/answer HTTP/1.1\r\nHost: h\r\nContent-Length: 11\r\n\r\n{\"a\":true}\n".utf8)

private func status(_ text: String) -> Int? {
    var parser = HTTPParser()
    if case .failure(let error)? = parser.feed(Data(text.utf8)).first { return error.status }
    return nil
}

@Test func aRequestSplitAtEveryByteParsesTheSame() throws {
    var whole = HTTPParser()
    let bytes = get + post + get
    let expected = try whole.feed(bytes).map { try $0.get() }
    #expect(expected.map(\.method) == ["GET", "POST", "GET"])
    #expect(expected[0].path == ["v1", "sessions", "a b", "transcript"] && expected[0].query == ["after": "4", "limit": "50"])
    #expect(expected[1].body == Data("{\"a\":true}\n".utf8))
    for cut in 1..<bytes.count {
        var parser = HTTPParser()
        let parts = parser.feed(bytes.prefix(cut)) + parser.feed(bytes.dropFirst(cut))
        #expect(try parts.map { try $0.get() } == expected)
    }
}

@Test func refusesWhatCouldBeFramedTwoWays() {
    #expect(status("POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n") == 411)
    #expect(status("POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx") == 400)
    #expect(status("GET / HTTP/1.1\r\nHost: h\r\n folded\r\n\r\n") == 400)
    #expect(status("GET / HTTP/1.1\r\nHost: h\rX: y\r\n\r\n") == 400)
    #expect(status("GET / HTTP/1.1\r\nHöst: h\r\n\r\n") == 400)
    #expect(status("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == 400)
    #expect(status("PUT / HTTP/1.1\r\nHost: h\r\n\r\n") == 405)
    #expect(status("POST / HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 1\r\n\r\n") == 417)
    #expect(status("GET /v1/../etc HTTP/1.1\r\n\r\n") == 400)
    #expect(status("GET /v1/a%2Fb HTTP/1.1\r\n\r\n") == 400)
    #expect(status("GET http://x/v1 HTTP/1.1\r\n\r\n") == 400)
}

@Test func headersOverSixteenKilobytesAre431AndOneByteLessIsnt() {
    let line = "GET / HTTP/1.1\r\n"
    let filler = { (size: Int) in line + "X: " + String(repeating: "a", count: size - line.utf8.count - 3 - 4) + "\r\n\r\n" }
    #expect(filler(16 << 10).utf8.count == 16 << 10)
    #expect(status(filler(16 << 10)) == nil)
    #expect(status(filler((16 << 10) + 1)) == 431)
    // Without an end in sight, the parser stops reading at the limit.
    var parser = HTTPParser()
    #expect(parser.feed(Data((line + String(repeating: "X: y\r\n", count: 3000)).utf8)).first.map { (try? $0.get()) == nil } == true)
    #expect(status("GET /" + String(repeating: "a", count: 9000) + " HTTP/1.1\r\n") == 414)
    #expect(status(line + String(repeating: "X: y\r\n", count: 65) + "\r\n") == 431)
}

@Test func bodiesHaveALimitPerRoute() {
    let over = (1 << 20) + 1
    #expect(status("POST /v1/x HTTP/1.1\r\nContent-Length: \(over)\r\n\r\n") == 413)
    var uploads = HTTPParser { head in head.path == ["v1", "uploads"] ? 2 << 20 : nil }
    let upload = Data("POST /v1/uploads HTTP/1.1\r\nContent-Length: \(over)\r\n\r\n".utf8) + Data(count: over)
    #expect((try? uploads.feed(upload).first?.get())?.body.count == over)
}

@Test func anUpgradeStopsParsingAndHandsOverTheRest() throws {
    var parser = HTTPParser()
    let upgrade = "GET /v1/ws/events HTTP/1.1\r\nHost: h\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"
    let out = try parser.feed(Data(upgrade.utf8) + Data([0x81, 0x80])).map { try $0.get() }
    #expect(out.count == 1 && out[0].wantsUpgrade && parser.takeRemainder() == Data([0x81, 0x80]))
}

@Test func responsesAlwaysCarryALength() {
    let text = String(decoding: HTTPResponse.json(200, Data("{}".utf8)).encoded(close: true), as: UTF8.self)
    #expect(text == "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
    #expect(String(decoding: HTTPResponse(status: 204).encoded(close: false), as: UTF8.self) == "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
}
