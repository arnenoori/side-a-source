import Foundation
import Network
@testable import SideARemoteKit
import Testing

struct HTTPStreamTests {
    func stream() -> HTTPStream {
        HTTPStream(connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: DispatchQueue(label: "http.test"))
    }

    func failure(_ text: String) -> HTTPStream.Failure? {
        guard case .failure(let failure)? = stream().feed(Data(text.utf8)) else { return nil }
        return failure
    }

    @Test func sizesFromTheWireNeverTrap() {
        #expect(failure("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n") == .malformed)
        #expect(failure("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-1\r\nx\r\n") == .malformed)
        #expect(failure("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\n") == .malformed)
        #expect(failure("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nffffffff\r\n") == .tooLarge)
        #expect(failure("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nabXY0\r\n\r\n") == .malformed)
    }

    @Test func trailersAreReadToTheEndSoTheNextResponseParses() throws {
        let stream = stream()
        let first = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\nX-Trailer: 1\r\n\r\n"
        let second = "HTTP/1.1 204 No Content\r\n\r\n"
        guard case .success(let reply)? = stream.feed(Data((first + second).utf8)) else { Issue.record("no first reply"); return }
        #expect(reply.body == Data("abc".utf8))
        guard case .success(let next)? = stream.feed(Data()) else { Issue.record("no second reply"); return }
        #expect(next.status == 204)
    }

    @Test func aChunkedBodyWithoutTrailersEndsAtTheEmptyLine() {
        guard case .success(let reply)? = stream().feed(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nz\r\n0\r\n\r\n".utf8)) else {
            Issue.record("no reply"); return
        }
        #expect(reply.body == Data("z".utf8))
    }
}
