import Darwin
import Foundation

/// A connection that closes before the answer means the CLI stopped the hook, as when its session quits.
final class IslandServer: @unchecked Sendable {
    typealias Received = @Sendable (_ id: UInt64, _ line: Data) -> Void
    typealias Closed = @Sendable (_ id: UInt64) -> Void

    let path: String
    private let queue = DispatchQueue(label: "com.arnenoori.sidea.island")
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [UInt64: Connection] = [:]
    private var nextID: UInt64 = 0
    private let received: Received
    private let closed: Closed

    private final class Connection {
        let fd: Int32
        var buffer = Data()
        var delivered = false
        var source: DispatchSourceRead?
        init(fd: Int32) { self.fd = fd }
    }

    init(path: String, received: @escaping Received, closed: @escaping Closed) {
        self.path = path; self.received = received; self.closed = closed
    }

    func start() throws {
        try queue.sync {
            guard listener < 0 else { return }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw BridgeFailure(message: "The island's socket path is too long.") }
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw BridgeFailure(message: "The island couldn't open its socket.") }
            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
            guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
                close(fd)
                throw BridgeFailure(message: "The island couldn't listen for permission requests.")
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            listener = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.accept() }
            source.resume()
            acceptSource = source
        }
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel(); acceptSource = nil
            if listener >= 0 { close(listener); listener = -1; unlink(path) }
            for id in Array(connections.keys) { drop(id, notify: false) }
        }
    }

    func reply(_ id: UInt64, _ line: Data) {
        queue.async { [self] in
            guard let connection = connections[id] else { return }
            line.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(connection.fd, raw.baseAddress! + offset, raw.count - offset)
                    if written > 0 { offset += written } else if errno != EINTR && errno != EAGAIN { break }
                }
            }
            drop(id, notify: false)
        }
    }

    private func accept() {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            // Another user on this Mac can't reach the folder, but check the peer anyway: answers grant permissions.
            var uid = uid_t(0), gid = gid_t(0)
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); continue }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            nextID += 1
            let id = nextID
            let connection = Connection(fd: fd)
            connections[id] = connection
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(id) }
            connection.source = source
            source.resume()
        }
    }

    private func read(_ id: UInt64) {
        guard let connection = connections[id] else { return }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(connection.fd, &chunk, chunk.count)
        if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
            drop(id, notify: connection.delivered)
            return
        }
        guard count > 0, !connection.delivered else { return }
        connection.buffer.append(contentsOf: chunk[0..<count])
        if connection.buffer.count > 4 << 20 { drop(id, notify: false); return }
        if let newline = connection.buffer.firstIndex(of: 10) {
            connection.delivered = true
            received(id, connection.buffer[..<newline])
            connection.buffer = Data()
        }
    }

    private func drop(_ id: UInt64, notify: Bool) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.source?.cancel()
        close(connection.fd)
        if notify { closed(id) }
    }
}
