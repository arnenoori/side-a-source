import Foundation
import Testing
@testable import SideA
import SideACore

/// The log never carries an attempt id, a preview credential or a query, and keeps three files of at most 2 MB.
@Test func theRemoteLogRedactsPathsAndRotates() throws {
    func request(_ target: String) -> HTTPRequest {
        let path = target.split(separator: "?").first.map { $0.split(separator: "/").map(String.init) } ?? []
        return HTTPRequest(method: "GET", target: target, path: path, query: [:], headers: HTTPHeaders([]), body: Data())
    }
    #expect(RemoteLog.path(request("/v1/pair/att-secret/wait")) == "/v1/pair/…/wait")
    #expect(RemoteLog.path(request("/v1/preview/cred-secret/assets/app.js")) == "/v1/preview/…")
    #expect(RemoteLog.path(request("/v1/history?cursor=o50")) == "/v1/history")
    #expect(RemoteLog.path(request("/assets/app.js")) == "/(preview page)")
    #expect(RemoteLog.network("100.101.102.103") == "tailnet" && RemoteLog.network("192.168.1.4") == "LAN" && RemoteLog.network("127.0.0.1") == "loopback")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remote-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = RemoteLog()
    let url = folder.appendingPathComponent("remote.log")
    log.open(url)
    let line = String(repeating: "x", count: 1_000)
    for _ in 0..<(3 * RemoteLog.fileLimit / 1_000 + 10) { log(line) }
    _ = log.recent
    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(files == ["remote.1.log", "remote.2.log", "remote.log"])
    for file in files {
        let size = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file).path)[.size] as? Int ?? 0
        #expect(size <= RemoteLog.fileLimit + 1_100)
    }
    #expect(log.recent.count == RemoteLog.kept)
}
