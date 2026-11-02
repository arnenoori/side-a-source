import Darwin
import Foundation

/// A plain BSD listening socket on one of the Mac's addresses that hands every connection, bytes untouched, to the TLS
/// listener on loopback. Network.framework's own listener accepts on a Tailscale address but never finishes the
/// handshake: the connection stays preparing on utun until the peer gives up (checked from another tailnet Mac,
/// Tailscale 1.104.1, firewall permitting both). BSD sockets on the same address work, so the outside faces BSD.
final class SocketFront: @unchecked Sendable {
    /// Connections in flight through one front; past it new ones are closed at once.
    static let maxPairs = 64

    private let fd: Int32
    private let source: DispatchSourceRead
    /// The port it listens on, as bound (asking for 0 takes any free one).
    let port: UInt16
    private let pairs = Pairs()

    /// `target` runs on `queue` for each connection and names the loopback port to hand it to, nil while there is none.
    init(address: String, port: UInt16, queue: DispatchQueue, target: @escaping () -> UInt16?) throws {
        let ipv6 = address.contains(":")
        fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        if ipv6 { setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size)) }
        let bound = ipv6 ? Self.bind(fd, v6: address, port: port) : Self.bind(fd, v4: address, port: port)
        guard bound, listen(fd, 32) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            throw POSIXError(code)
        }
        var named = sockaddr_storage()
        var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let listening = fd
        _ = withUnsafeMutablePointer(to: &named) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listening, $0, &size) } }
        // sin_port and sin6_port share an offset.
        self.port = UInt16(bigEndian: withUnsafeBytes(of: named) { $0.load(fromByteOffset: 2, as: UInt16.self) })
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let fd = fd, pairs = pairs, local = "\(ipv6 ? "[\(address)]" : address):\(port)", network = RemoteLog.network(address)
        source.setEventHandler {
            while true {
                var storage = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let client = withUnsafeMutablePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) }
                }
                guard client >= 0 else { return }
                let (address, service) = Self.describe(storage)
                let peer = "\(network) \(address.contains(":") ? "[\(address)]" : address):\(service) → \(local)"
                guard pairs.count < Self.maxPairs else { RemoteLog.shared("refused \(peer): \(Self.maxPairs) connections open"); close(client); continue }
                guard let port = target(), let server = Self.connect(loopback: port) else {
                    RemoteLog.shared("refused \(peer): the TLS listener isn't up")
                    close(client); continue
                }
                if let spliced = Self.localPort(server) { SplicedPeers.shared.set(spliced, peer, source: address) }
                RemoteLog.shared("accepted \(peer)")
                Splice.start(client, server, pairs: pairs)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    /// Stops listening. Connections already handed over carry on until either end closes.
    func cancel() { source.cancel() }

    private static func bind(_ fd: Int32, v4 address: String, port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { errno = EADDRNOTAVAIL; return false }
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    private static func bind(_ fd: Int32, v6 address: String, port: UInt16) -> Bool {
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        guard inet_pton(AF_INET6, address, &addr.sin6_addr) == 1 else { errno = EADDRNOTAVAIL; return false }
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } } == 0
    }

    /// ("192.168.1.20", "51234") or ("fd7a::1", "51234").
    private static func describe(_ storage: sockaddr_storage) -> (address: String, service: String) {
        var storage = storage
        let length = socklen_t(storage.ss_len)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST)), service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let found = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), &service, socklen_t(service.count), NI_NUMERICHOST | NI_NUMERICSERV)
            }
        }
        guard found == 0 else { return ("?", "?") }
        func text(_ chars: [CChar]) -> String { String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        return (text(host), text(service))
    }

    /// The loopback port this end of the splice uses, which the TLS listener sees as its peer's.
    private static func localPort(_ fd: Int32) -> UInt16? {
        var addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return got == 0 ? UInt16(bigEndian: addr.sin_port) : nil
    }

    /// Loopback connects at once, so this blocks for no time worth counting.
    private static func connect(loopback port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { close(fd); return nil }
        return fd
    }

    final class Pairs: @unchecked Sendable {
        private let lock = NSLock()
        private var open = 0
        var count: Int { lock.withLock { open } }
        func add() { lock.withLock { open += 1 } }
        func remove() { lock.withLock { open -= 1 } }
    }
}

/// Copies bytes both ways between the phone's socket and the loopback one. Each direction has its own queue and
/// writes everything it reads before reading more, so a slow reader slows its writer and nothing piles up here.
private final class Splice: @unchecked Sendable {
    /// A write that can't move for this long ends the pair; the server's keepalive notices the same phone sooner.
    static let stalledFor: Int32 = 60_000

    private let client: Int32
    private let server: Int32
    private let pairs: SocketFront.Pairs
    private let lock = NSLock()
    private var sources: [DispatchSourceRead] = []
    private var live = 2

    private init(client: Int32, server: Int32, pairs: SocketFront.Pairs) {
        self.client = client; self.server = server; self.pairs = pairs
    }

    static func start(_ client: Int32, _ server: Int32, pairs: SocketFront.Pairs) {
        var yes: Int32 = 1
        for fd in [client, server] {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        pairs.add()
        let splice = Splice(client: client, server: server, pairs: pairs)
        // The phone closing its side is passed on; the server closing ends the pair, since it never half-closes.
        let up = splice.pipe(from: client, to: server, label: "up") { splice.halfClose() }
        let down = splice.pipe(from: server, to: client, label: "down") { splice.finish() }
        splice.lock.withLock { splice.sources = [up, down] }
        up.resume(); down.resume()
    }

    private func pipe(from: Int32, to: Int32, label: String, ended: @escaping () -> Void) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: from, queue: DispatchQueue(label: "com.arnenoori.sidea.remote.splice." + label))
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        source.setEventHandler { [self] in
            let count = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress, $0.count) }
            if count > 0 {
                if !buffer.withUnsafeBytes({ Self.write(to, $0.baseAddress!, count) }) { finish() }
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                count == 0 ? ended() : finish()
            }
        }
        source.setCancelHandler { [self] in
            let last = lock.withLock { live -= 1; return live == 0 }
            if last { close(client); close(server); pairs.remove() }
        }
        return source
    }

    private func halfClose() {
        shutdown(server, SHUT_WR)
        lock.withLock { sources.first }?.cancel()
    }

    private func finish() {
        for source in lock.withLock({ sources }) { source.cancel() }
    }

    private static func write(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Bool {
        var sent = 0
        while sent < count {
            let n = Darwin.write(fd, bytes + sent, count - sent)
            if n > 0 { sent += n; continue }
            guard n < 0, errno == EAGAIN || errno == EINTR else { return false }
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&poller, 1, stalledFor) > 0 else { return false }
        }
        return true
    }
}
