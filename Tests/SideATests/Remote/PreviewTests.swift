import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import SideARemoteKit
import Testing

/// The preview proxy through the real listener to a real dev server: its credential opens one port and nothing else,
/// the cookie carries a page's absolute links, and an expired one, another site's page or a bare request get nothing.
@Test func aPreviewOpensOnePortForItsOwnPagesOnly() async throws {
    let keychain = try TestKeychain()
    let site = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sidea-preview-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: site.appendingPathComponent("docs"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: site) }
    try "<h1>Dev</h1>".write(to: site.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    try "absolute".write(to: site.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)
    let devPort = freePort()
    let dev = Process()
    dev.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    dev.arguments = ["-m", "http.server", String(devPort), "--bind", "127.0.0.1", "--directory", site.path]
    dev.standardOutput = FileHandle.nullDevice
    dev.standardError = FileHandle.nullDevice
    try dev.run()
    defer { dev.terminate() }

    let identity = try #require(try keychain.store.identity())
    let server = RemoteServer(identity: identity, epoch: "e1") { _, _ in HTTPResponse(status: 200) }
    server.proxy = { request, port, target, cookie in await PreviewProxy.forward(request, port: port, target: target, cookie: cookie) }
    let token = DeviceToken.make()
    server.setDevices([(id: "d1", hash: DeviceToken.hash(token))])
    server.setPreviews(["live": .init(port: devPort, device: "d1", expires: Date().addingTimeInterval(60)),
                        "old": .init(port: devPort, device: "d1", expires: Date().addingTimeInterval(-1)),
                        "dead": .init(port: 9, device: "d1", expires: Date().addingTimeInterval(60))])
    let port = freePort()
    server.serve(addresses: ["127.0.0.1"], port: port)
    defer { server.stop() }
    for _ in 0..<250 where server.listenerStates.values.first != .ready { try await Task.sleep(for: .milliseconds(20)) }

    let transport = URLSessionTransport(trust: PinnedTrust(.pinned(identity.spkiHash.base64URL)))
    func get(_ path: String, _ headers: [String: String] = [:]) async throws -> (Int, String, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)\(path)")!)
        request.httpShouldHandleCookies = false
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (body, response) = try await transport.send(request)
        return (response.statusCode, String(decoding: body, as: UTF8.self), response)
    }
    // Until the dev server is up the link stays unspent (502); its first page load spends it.
    var first: (Int, String, HTTPURLResponse)?
    for _ in 0..<100 {
        if let got = try? await get("/v1/preview/live/"), got.0 == 200 { first = got; break }
        try await Task.sleep(for: .milliseconds(50))
    }
    let (status, body, response) = try #require(first)
    #expect(status == 200 && body == "<h1>Dev</h1>")
    #expect(response.value(forHTTPHeaderField: "Set-Cookie")?.hasPrefix("sidea_preview=live; Path=/;") == true)
    // After that the link needs the cookie its first load set: copied to another browser it opens nothing.
    let session = ["Cookie": "sidea_preview=live"]
    #expect(try await get("/v1/preview/live/").0 == 404)
    #expect(try await get("/v1/preview/live/app.js", session).1 == "absolute")
    // A page's absolute link, with the cookie.
    #expect(try await get("/app.js", ["Cookie": "theme=dark; sidea_preview=live"]).1 == "absolute")
    // The page's own origin may send Origin; another site's may not.
    #expect(try await get("/v1/preview/live/", ["Origin": "https://127.0.0.1:\(port)", "Sec-Fetch-Site": "same-origin"].merging(session) { $1 }).0 == 200)
    #expect(try await get("/v1/preview/live/", ["Origin": "https://evil.example"]).0 == 403)
    #expect(try await get("/app.js", ["Cookie": "sidea_preview=live", "Sec-Fetch-Site": "cross-site"]).0 == 403)

    // Nothing else opens it, and it opens nothing else.
    #expect(try await get("/app.js").0 == 401)
    #expect(try await get("/v1/preview/guess/").0 == 401)
    #expect(try await get("/v1/preview/old/").0 == 404)
    #expect(try await get("/app.js", ["Cookie": "sidea_preview=old"]).0 == 404)
    #expect(try await get("/v1/sessions", ["Cookie": "sidea_preview=live"]).0 == 401)
    #expect(try await get("/v1/preview/dead/").0 == 502)

    // Paired again under the same id: the old token's previews go, by path and by cookie.
    server.setDevices([(id: "d1", hash: DeviceToken.hash(DeviceToken.make()))])
    #expect(try await get("/v1/preview/live/").0 == 401)
    #expect(try await get("/app.js", ["Cookie": "sidea_preview=live"]).0 == 401)

    // Only while the dev server it opened on still listens there: another process on the port gets nothing.
    #expect(PortOwner.listens(pid: dev.processIdentifier, port: devPort))
    #expect(!PortOwner.listens(pid: dev.processIdentifier, port: devPort &+ 1) && !PortOwner.listens(pid: getpid(), port: devPort))
    server.setPreviews(["owned": .init(port: devPort, pid: dev.processIdentifier, device: "d1", expires: Date().addingTimeInterval(60)),
                        "stranger": .init(port: devPort, pid: getpid(), device: "d1", expires: Date().addingTimeInterval(60))])
    #expect(try await get("/v1/preview/owned/").0 == 200)
    #expect(try await get("/v1/preview/stranger/").0 == 404)

    #expect(PreviewProxy.local("http://localhost:5173/login?x=1", port: 5173) == "/login?x=1")
    #expect(PreviewProxy.local("https://example.com/", port: 5173) == "https://example.com/")
}

/// A dev server that never stops sending, or says it will send too much, is cut off at the budget, not collected.
@Test func aPreviewResponseIsCutOffAtItsBudget() async throws {
    let port = freePort()
    let script = """
    import socket, sys
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(8)
    chunk = b"x" * 65536
    while True:
        c, _ = s.accept()
        request = c.recv(65536)
        try:
            if b"/announced" in request:
                c.sendall(b"HTTP/1.1 200 OK\\r\\nContent-Length: 999999999999\\r\\n\\r\\n" + chunk)
            else:
                c.sendall(b"HTTP/1.0 200 OK\\r\\nContent-Type: text/plain\\r\\n\\r\\n")
                while True: c.sendall(chunk)
        except Exception:
            pass
        c.close()
    """
    let dev = Process()
    dev.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    dev.arguments = ["-c", script, String(port)]
    dev.standardOutput = FileHandle.nullDevice
    dev.standardError = FileHandle.nullDevice
    try dev.run()
    defer { dev.terminate() }
    let request = HTTPRequest(method: "GET", target: "/", path: [], query: [:], headers: HTTPHeaders([]), body: Data())
    var response = HTTPResponse(status: 0)
    for _ in 0..<100 {
        response = await PreviewProxy.forward(request, port: port, target: "/announced", cookie: nil)
        if response.status == 502, String(decoding: response.body, as: UTF8.self).contains("preview_too_large") { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(String(decoding: response.body, as: UTF8.self).contains("preview_too_large"))
    let start = Date()
    let endless = await PreviewProxy.forward(request, port: port, target: "/endless", cookie: nil)
    #expect(endless.status == 502 && String(decoding: endless.body, as: UTF8.self).contains("preview_too_large"))
    #expect(Date().timeIntervalSince(start) < 10)
}
