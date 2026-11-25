@testable import SideACore
import Testing

@Test func aRoutesKeyKeepsItsWordsAndLosesItsIds() {
    #expect(Traffic.key(method: "GET", path: ["v1", "sessions", "5d368354-d4f2-49fe-98df-169acc5b11cb", "transcript"]) == "GET /v1/sessions/*/transcript")
    #expect(Traffic.key(method: "WS", path: ["v1", "ws", "term", "sa-side-a-1f2e"]) == "WS /v1/ws/term/*")
    #expect(Traffic.key(method: "GET", path: ["v1", "history"]) == "GET /v1/history")
    #expect(Traffic.key(method: "POST", path: ["v1", "sessions", "pid-123-456", "ports", "3000", "stop"]) == "POST /v1/sessions/*/ports/*/stop")
}

@Test func theTotalNamesTheHeaviestRoutesAndNothingElse() throws {
    let traffic = Traffic()
    traffic.add("GET /v1/sessions/*/transcript", count: 2, received: 400, sent: 3 << 20)
    traffic.add("WS /v1/ws/events", received: 50, sent: 20_000)
    traffic.add("GET /v1/hello", count: 30, received: 3_000, sent: 9_000)
    let line = try #require(Traffic.summary(traffic.drain(), seconds: 60, limit: 2))
    #expect(line.hasPrefix("traffic 60 s: 3.0 MB out, 3.4 KB in; GET /v1/sessions/*/transcript 2 req 3.0 MB out"))
    #expect(line.contains("WS /v1/ws/events") && !line.contains("hello"))
    #expect(Traffic.summary(traffic.drain(), seconds: 60) == nil)
}
