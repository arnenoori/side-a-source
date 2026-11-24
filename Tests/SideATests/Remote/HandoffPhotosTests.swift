import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

/// A handoff carries photos the phone uploaded itself, and only those, before anything starts or ends.
@MainActor
private final class HandoffScene {
    let store = AccountStore(demo: true)

    init() throws {
        store.remote.confirmCheck = { _, _, _, _, _ in nil }
        let live = ["pid": 501, "status": "idle", "cwd": "/tmp/app", "started": 1_700_000_000, "agent": "claude", "id": "s1"] as [String: Any]
        store.sessions.live.append(try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: live)))
    }

    func call(_ method: String, _ path: String, _ body: Data, device: String) async -> (status: Int, reason: String?) {
        let route = path.split(separator: "/").map(String.init)
        let request = HTTPRequest(method: method, target: "/" + path, path: route, query: [:], headers: HTTPHeaders([]), body: body)
        let response = await RemoteRoutes.route(request, RemoteServer.Caller(device: device, connection: 1), store.remote)
        let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        let error = object["error"] as? [String: Any] ?? [:]
        let details = error["details"] as? [String: Any] ?? [:]
        return (response.status, details["reason"] as? String)
    }

    func upload(device: String) async throws -> String {
        let response = await {
            let request = HTTPRequest(method: "POST", target: "/v1/uploads", path: ["v1", "uploads"], query: [:], headers: HTTPHeaders([]),
                                      body: TranscriptFixture.image)
            return await RemoteRoutes.route(request, RemoteServer.Caller(device: device, connection: 1), store.remote)
        }()
        #expect(response.status == 201)
        let object = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        return try #require(object["id"] as? String)
    }

    func restart(photos: [String], device: String) async throws -> (status: Int, reason: String?) {
        let handoff = Handoff(goal: "g", failed: "", next: "", lastMessages: "", cwd: "/tmp/app", project: "app")
        let body = try JSONEncoder().encode(RestartRequest(handoff: handoff, agent: .codex, message: "Look at this", attachments: photos))
        return await call("POST", "v1/sessions/s1/restart", body, device: device)
    }
}

@MainActor @Test func aHandoffNamingAPhotoTheMacDoesNotHaveStartsNothing() async throws {
    let scene = try HandoffScene()
    let (status, reason) = try await scene.restart(photos: ["0123456789ab"], device: "d1")
    #expect(status == 422 && reason == "unknown_upload", "\(status) \(reason ?? "")")
}

@MainActor @Test func aHandoffCannotUseAnotherPhonesUpload() async throws {
    let scene = try HandoffScene()
    // Device names no other test uploads as: the same photo is the same id, and a shared name would find it.
    let theirs = try await scene.upload(device: "handoff-other-phone")
    let (status, reason) = try await scene.restart(photos: [theirs], device: "handoff-this-phone")
    #expect(status == 422 && reason == "unknown_upload", "\(status) \(reason ?? "")")
}

@MainActor @Test func aHandoffTakesAtMostTenPhotos() async throws {
    let scene = try HandoffScene()
    let (status, reason) = try await scene.restart(photos: (0..<11).map { String(format: "%012x", $0) }, device: "d1")
    #expect(status == 422 && reason == "too_many", "\(status) \(reason ?? "")")
}

@MainActor @Test func aHandoffWithThePhonesOwnPhotoGetsPastTheUploadCheck() async throws {
    let scene = try HandoffScene()
    let mine = try await scene.upload(device: "handoff-own-phone")
    let (status, reason) = try await scene.restart(photos: [mine], device: "handoff-own-phone")
    // The demo Mac has no tmux to start the other agent in, so it answers after the photos were accepted.
    #expect(reason != "unknown_upload" && reason != "too_many" && status != 201, "\(status) \(reason ?? "")")
}
