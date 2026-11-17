import Foundation
import SideAProtocol
import Testing

@Test func eachQueuedRouteHasItsLiteralMethodPatternAndPath() {
    #expect(QueuedRoutes.answer.method == "POST" && QueuedRoutes.answer.pattern == "v1/requests/{rid}/answer")
    #expect(QueuedRoutes.reply.method == "POST" && QueuedRoutes.reply.pattern == "v1/sessions/{id}/reply")
    #expect(QueuedRoutes.interrupt.method == "POST" && QueuedRoutes.interrupt.pattern == "v1/sessions/{id}/interrupt")
    #expect(QueuedRoutes.takeBack.method == "DELETE" && QueuedRoutes.takeBack.pattern == "v1/sessions/{id}/mail")
    #expect(QueuedRoutes.answer.path("r1") == "/v1/requests/r1/answer")
    #expect(QueuedRoutes.reply.path("s1") == "/v1/sessions/s1/reply")
    #expect(QueuedRoutes.interrupt.path("s1") == "/v1/sessions/s1/interrupt")
    #expect(QueuedRoutes.takeBack.path("s1") == "/v1/sessions/s1/mail")
}

@Test func aRouteReadsItsOwnPathsIdAndNoOthers() {
    #expect(QueuedRoutes.answer.id(inPath: "/v1/requests/r1/answer") == "r1")
    #expect(QueuedRoutes.answer.id(inPath: "/v1/requests/r1/reply") == nil)
    #expect(QueuedRoutes.answer.id(inPath: "/v1/sessions/r1/answer") == nil)
    #expect(QueuedRoutes.answer.id(inPath: "/v1/requests/r1") == nil && QueuedRoutes.answer.id(inPath: "/v1/requests/r1/answer/x") == nil)
    #expect(QueuedRoutes.reply.id(inPath: "/v1/sessions/s1/reply") == "s1")
    #expect(QueuedRoutes.answering(path: "/v1/requests/a%2Fb/answer") == "a/b")
}

@Test func theTargetIsWhatThePathsCollectionAndIdSay() {
    #expect(QueuedRoutes.target(ofPath: QueuedRoutes.answer.path("r1")) == "request:r1")
    for route in [QueuedRoutes.reply, QueuedRoutes.interrupt, QueuedRoutes.takeBack] {
        #expect(QueuedRoutes.target(ofPath: route.path("s1")) == "session:s1")
    }
    #expect(QueuedRoutes.target(ofPath: "/v1/state") == "/v1/state")
}

@Test func theServerClassifiesOnlyTheRoutesItServes() {
    let components = ["v1", "sessions", "s1", "reply"]
    #expect(QueuedRoutes.reply.matches(method: "POST", components: components))
    #expect(!QueuedRoutes.reply.matches(method: "GET", components: components))
    #expect(!QueuedRoutes.interrupt.matches(method: "POST", components: components))
    #expect(!QueuedRoutes.reply.matches(method: "POST", components: ["v1", "sessions", "s1", "reply", "x"]))
    #expect(!QueuedRoutes.reply.matches(method: "POST", components: ["v2", "sessions", "s1", "reply"]))
    #expect(QueuedRoutes.takeBack.matches(method: "DELETE", components: ["v1", "sessions", "s1", "mail"]))
}
