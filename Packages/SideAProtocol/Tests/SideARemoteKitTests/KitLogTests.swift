import Foundation
@testable import SideARemoteKit
import Testing

@Test func loggedPathsLeaveOutQueriesAttemptIDsAndPreviewCredentials() throws {
    func path(_ text: String) throws -> String { KitLog.path(try #require(URL(string: text))) }
    #expect(try path("https://100.101.12.4:47800/v1/hello") == "/v1/hello")
    #expect(try path("https://100.101.12.4:47800/v1/sessions/s1/transcript?since=4&token=sa1_secret#frag") == "/v1/sessions/s1/transcript")
    #expect(try path("https://100.101.12.4:47800/v1/pair") == "/v1/pair")
    #expect(try path("https://100.101.12.4:47800/v1/pair/0f9c3a2e-attempt/wait") == "/v1/pair/…/wait")
    #expect(try path("https://100.101.12.4:47800/v1/pair/0f9c3a2e-attempt") == "/v1/pair/…")
    #expect(try path("https://100.101.12.4:47800/v1/preview/3000/c_secretcredential/index.html?x=1") == "/v1/preview/…")
    #expect(try path("https://100.101.12.4:47800/v1/preview") == "/v1/preview/…")
    #expect(try path("https://100.101.12.4:47800/app/settings?session=abc") == "/(preview page)")
    #expect(try path("https://100.101.12.4:47800/") == "/(preview page)")
    #expect(KitLog.path(nil) == "?")
}

@Test func aRequestLineCarriesNoQueryOrHeaders() throws {
    var request = URLRequest(url: try #require(URL(string: "https://192.168.1.20:47800/v1/pair/attempt-1/wait?code=K7QF29XM")))
    request.httpMethod = "POST"
    request.setValue("Bearer sa1_secret", forHTTPHeaderField: "Authorization")
    let line = KitLog.line(request)
    #expect(line == "POST 192.168.1.20:47800/v1/pair/…/wait [lan]")
    #expect(!line.contains("secret") && !line.contains("K7QF") && !line.contains("attempt-1"))
}
