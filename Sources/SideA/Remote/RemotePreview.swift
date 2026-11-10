import Foundation
import SideACore
import SideAProtocol

/// Dev server previews (protocol's Preview): a session's port served to the phone through Side A's own pinned
/// listener, never Tailscale Serve, so it reaches only the phone that asked. Each preview has a random credential
/// in its URL that becomes a cookie, and lasts 30 minutes, until its session stops listening, or until it's closed.
@MainActor
final class RemotePreviews {
    nonisolated static let lifetime: TimeInterval = 30 * 60

    struct Preview: Equatable {
        let token: String
        let session: SessionKey
        let port: Int
        /// The dev server listening on it when the preview opened; another process on the port later gets nothing.
        let pid: Int32
        let device: String
        let expires: Date
        let url: String
    }

    private(set) var previews: [String: Preview] = [:]
    private weak var controller: RemoteController?
    private var pruner: Task<Void, Never>?

    init(controller: RemoteController) { self.controller = controller }

    /// A fresh credential each time, replacing this phone's last one for the port: its link opens one page load only
    /// (RemoteServer), so a sheet opened again needs a new one. `host` is the address the phone used.
    func open(session: SessionKey, port: Int, pid: Int32, device: String, host: String) -> Preview {
        previews = previews.filter { !($0.value.session == session && $0.value.port == port && $0.value.device == device) }
        let token = Data((0..<24).map { _ in UInt8.random(in: 0...255) }).base64URL
        let preview = Preview(token: token, session: session, port: port, pid: pid, device: device, expires: Date().addingTimeInterval(Self.lifetime),
                              url: "https://\(host)/v1/preview/\(token)/")
        previews[token] = preview
        changed()
        return preview
    }

    func close(session: SessionKey, port: Int) {
        let before = previews.count
        previews = previews.filter { !($0.value.session == session && $0.value.port == port) }
        if previews.count != before { changed() }
    }

    func url(session: SessionKey, port: Int) -> String? {
        previews.values.first { $0.session == session && $0.port == port && $0.expires > Date() }?.url
    }

    /// Expired ones, and ones whose session no longer listens on the port.
    func prune(listening: [SessionKey: Set<Int>]) {
        let next = previews.filter { $0.value.expires > Date() && listening[$0.value.session]?.contains($0.value.port) == true }
        if next.count != previews.count {
            previews = next
            changed()
        }
    }

    func revoke(device: String) {
        let next = previews.filter { $0.value.device != device }
        if next.count != previews.count { previews = next; changed() }
    }

    /// Remote off: a new server knows none of these credentials, so no session may go on offering them.
    func revokeAll() {
        guard !previews.isEmpty else { return }
        previews = [:]
        changed()
    }

    private func changed() {
        controller?.server?.setPreviews(previews.mapValues { RemoteServer.Preview(port: UInt16(clamping: $0.port), pid: $0.pid, device: $0.device, expires: $0.expires) })
        if previews.isEmpty { pruner?.cancel(); pruner = nil } else if pruner == nil {
            pruner = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard let self, let store = controller?.store else { return }
                    prune(listening: Self.listening(store))
                }
            }
        }
    }

    static func listening(_ store: AccountStore) -> [SessionKey: Set<Int>] {
        Dictionary(store.sessions.live.map { (WireBuilders.key($0), Set(($0.ports ?? []).map(\.port))) }, uniquingKeysWith: { $0.union($1) })
    }
}

/// Dev server previews through Side A's own listener.
extension RemoteRoutes {
    static let previewRoutes: [Route] = [
        Route("POST", "v1/sessions/{id}/ports/{port}/preview", openPreview),
        Route("DELETE", "v1/sessions/{id}/ports/{port}/preview", closePreview),
    ]

    static let portNotFound = RemoteServer.error(404, "port_not_found", "That session isn't listening on that port any more.")

    @Sendable static func openPreview(_ context: Context) async -> HTTPResponse {
        guard let port = context.params["port"].flatMap(Int.init), let host = context.request.headers["Host"] else { return portNotFound }
        let id = context.params["id"] ?? "", device = context.device
        if let refused = await refusal(context, .preview, target: "\(id):\(port)") { return refused }
        return await MainActor.run {
            guard let store = context.controller.store, let target = Target(id, store: store), let live = target.live,
                  let listener = live.ports?.first(where: { $0.port == port }) else { return portNotFound }
            struct Opened: Encodable { let url: String }
            let preview = context.controller.previews.open(session: target.key, port: port, pid: Int32(clamping: listener.pid), device: device, host: host)
            return json(200, Opened(url: preview.url))
        }
    }

    @Sendable static func closePreview(_ context: Context) async -> HTTPResponse {
        guard let port = context.params["port"].flatMap(Int.init) else { return portNotFound }
        let id = context.params["id"] ?? ""
        await MainActor.run {
            guard let store = context.controller.store, let target = Target(id, store: store) else { return }
            context.controller.previews.close(session: target.key, port: port)
        }
        return HTTPResponse(status: 204)
    }
}

/// Whether a process still listens on a TCP port, read from the kernel per request: a preview stops the moment its
/// dev server does, rather than at the next minute's prune, so whatever binds the port next never sees the phone's
/// cookies.
enum PortOwner {
    static func listens(pid: Int32, port: UInt16) -> Bool {
        guard pid > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return false }
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let read = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard read == MemoryLayout<socket_fdinfo>.size, info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            if UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)) == port { return true }
        }
        return false
    }
}

/// One request to the dev server on `127.0.0.1`. Redirects come back to the page as they are, with the dev server's
/// own origin taken off, so they stay inside the preview.
enum PreviewProxy {
    /// One response's most, counted as it streams in: a dev server that sends more is cut off there, not collected.
    static let maxBody = 32 << 20
    /// Requests forwarded at once, the rest waiting their turn, so at most `concurrent × maxBody` is ever held.
    static let concurrent = 4

    /// Collects each task's body up to the budget and cancels the task past it. Redirects come back unfollowed.
    private final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private struct Pending {
            var data = Data()
            let done: (Result<(Data, HTTPURLResponse), Error>) -> Void
            var response: HTTPURLResponse?
        }
        private let lock = NSLock()
        private var tasks: [Int: Pending] = [:]

        func start(_ task: URLSessionDataTask, done: @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void) {
            lock.withLock { tasks[task.taskIdentifier] = Pending(done: done) }
            task.resume()
        }

        private func finish(_ task: URLSessionTask, _ result: Result<(Data, HTTPURLResponse), Error>) {
            guard let pending = lock.withLock({ tasks.removeValue(forKey: task.taskIdentifier) }) else { return }
            pending.done(result)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return finish(dataTask, .failure(URLError(.badServerResponse))) }
            // Said too large up front: no byte of it is read.
            if http.expectedContentLength > Int64(maxBody) { completionHandler(.cancel); return finish(dataTask, .failure(TooLarge())) }
            lock.withLock { tasks[dataTask.taskIdentifier]?.response = http }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let over = lock.withLock { () -> Bool in
                guard tasks[dataTask.taskIdentifier] != nil else { return false }
                tasks[dataTask.taskIdentifier]!.data.append(data)
                return tasks[dataTask.taskIdentifier]!.data.count > maxBody
            }
            if over { dataTask.cancel(); finish(dataTask, .failure(TooLarge())) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let pending = lock.withLock { tasks[task.taskIdentifier] }
            if let error { return finish(task, .failure(error)) }
            guard let response = pending?.response else { return finish(task, .failure(URLError(.badServerResponse))) }
            finish(task, .success((pending?.data ?? Data(), response)))
        }
    }

    struct TooLarge: Error {}

    /// Waiting turns for `concurrent` forwarding slots.
    private actor Slots {
        private var free = PreviewProxy.concurrent
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func take() async {
            if free > 0 { free -= 1; return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func give() {
            if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
        }
    }

    private static let slots = Slots()
    private static let collector = Collector()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
    }()

    private static func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await slots.take()
        defer { Task { await slots.give() } }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.start(task) { continuation.resume(with: $0) }
            }
        } onCancel: { task.cancel() }
    }

    static let dropped: Set<String> = ["host", "connection", "keep-alive", "upgrade", "te", "trailer", "transfer-encoding", "proxy-authorization",
                                       "proxy-connection", "authorization", "content-length", "origin", "referer"]
    static let droppedBack: Set<String> = ["connection", "keep-alive", "transfer-encoding", "content-encoding", "content-length", "upgrade",
                                           "strict-transport-security", "alt-svc"]

    static func forward(_ request: HTTPRequest, port: UInt16, target: String, cookie: String?) async -> HTTPResponse {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(target)") else { return RemoteServer.error(400, "bad_request", "That address can't be previewed.") }
        var outgoing = URLRequest(url: url)
        outgoing.httpMethod = request.method
        outgoing.httpBody = request.method == "GET" ? nil : request.body
        for (name, value) in request.headers.fields where !dropped.contains(name.lowercased()) {
            if name.lowercased() == "cookie" {
                let kept = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.hasPrefix(RemoteServer.previewCookie + "=") }
                if !kept.isEmpty { outgoing.addValue(kept.joined(separator: "; "), forHTTPHeaderField: "Cookie") }
            } else {
                outgoing.addValue(value, forHTTPHeaderField: name)
            }
        }
        let data: Data, http: HTTPURLResponse
        do {
            (data, http) = try await fetch(outgoing)
        } catch is TooLarge {
            return RemoteServer.error(502, "preview_too_large", "That response is too large to preview.")
        } catch {
            return RemoteServer.error(502, "preview_unreachable", "Nothing answered on port \(port). Is the dev server still running?")
        }
        var response = HTTPResponse(status: http.statusCode, body: data)
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String, let value = value as? String, !droppedBack.contains(name.lowercased()) else { continue }
            if name.lowercased() == "location" {
                response.headers.add(name, local(value, port: port))
            } else if name.lowercased() == "set-cookie" {
                // URLSession folds several Set-Cookie headers into one, comma-separated.
                for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": value], for: url) {
                    response.headers.add("Set-Cookie", "\(cookie.name)=\(cookie.value); Path=\(cookie.path)\(cookie.isHTTPOnly ? "; HttpOnly" : ""); Secure")
                }
            } else {
                response.headers.add(name, value)
            }
        }
        if let cookie {
            response.headers.add("Set-Cookie", "\(RemoteServer.previewCookie)=\(cookie); Path=/; Max-Age=\(Int(RemotePreviews.lifetime)); Secure; HttpOnly; SameSite=Strict")
        }
        return response
    }

    /// `http://localhost:5173/login` → `/login`; anything else stays.
    static func local(_ location: String, port: UInt16) -> String {
        for origin in ["http://localhost:\(port)", "http://127.0.0.1:\(port)", "http://[::1]:\(port)"] where location.hasPrefix(origin) {
            let rest = String(location.dropFirst(origin.count))
            return rest.isEmpty ? "/" : rest
        }
        return location
    }
}
