import Foundation

/// Where the daemon keeps what it must remember: the TLS key, the paired devices' token hashes, the idempotency ledger.
/// Side A's own secrets go behind `SecretStore` so a Secret Service or DPAPI implementation can replace the 0600 files
/// (docs/ports/windows-linux-prd.md, Credential storage) without the daemon changing.
public protocol SecretStore: Sendable {
    func read(_ name: String) throws -> Data?
    func write(_ name: String, _ data: Data) throws
    func delete(_ name: String) throws
    /// Said by `sidead status`, so the person knows where the secrets are.
    var kind: String { get }
}

public enum SecretStoreError: Error, CustomStringConvertible {
    case permissions(String)
    public var description: String {
        switch self { case .permissions(let path): "\(path) must be readable only by you (mode 0600)." }
    }
}

/// Files under the state directory, mode 0600, in a directory of mode 0700. A file with looser permissions is refused
/// rather than trusted: someone else may have written it.
public struct FileSecretStore: SecretStore {
    public let directory: URL
    public var kind: String { "files in \(directory.path) (mode 0600)" }

    public init(directory: URL) { self.directory = directory }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    public func read(_ name: String) throws -> Data? {
        let path = url(name).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let mode = attributes[.posixPermissions] as? Int, mode & 0o077 == 0 else { throw SecretStoreError.permissions(path) }
        return try Data(contentsOf: url(name))
    }

    public func write(_ name: String, _ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = url(name)
        let temporary = directory.appendingPathComponent(".\(name).\(UUID().uuidString.prefix(8))")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temporary.path, target.path) != 0 {
            let reason = errno
            unlink(temporary.path)
            throw POSIXError(POSIXErrorCode(rawValue: reason) ?? .EIO)
        }
    }

    public func delete(_ name: String) throws {
        let path = url(name).path
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
    }
}

/// Where things live. `SIDEAD_HOME` (or `--state-dir`) overrides everything, which is what tests and containers use.
public struct DaemonPaths: Sendable {
    public let state: URL
    public let socket: URL

    public init(state: URL, socket: URL? = nil) {
        self.state = state
        self.socket = socket ?? Self.defaultSocket(state: state)
    }

    /// `$SIDEAD_HOME`, else `$XDG_STATE_HOME/side-a`, else `~/.local/state/side-a`.
    public static func resolve(override: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> DaemonPaths {
        if let override = override ?? environment["SIDEAD_HOME"], !override.isEmpty { return DaemonPaths(state: URL(fileURLWithPath: override)) }
        let base = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        return DaemonPaths(state: base.appendingPathComponent("side-a"))
    }

    /// A Unix socket path holds at most about 100 bytes, so a long state directory falls back to a short one in /tmp.
    static func defaultSocket(state: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let runtime = environment["XDG_RUNTIME_DIR"], !runtime.isEmpty {
            let path = runtime + "/side-a/sidead.sock"
            if path.utf8.count < 100 { return URL(fileURLWithPath: path) }
        }
        let direct = state.appendingPathComponent("sidead.sock")
        if direct.path.utf8.count < 100 { return direct }
        // FNV-1a: stable between runs, unlike `hashValue`, so `sidead pair` finds the daemon's socket again.
        let hash = state.path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return URL(fileURLWithPath: "/tmp/sidead-\(getuid())-\(String(hash, radix: 36).prefix(10)).sock")
    }
}

/// A small JSON document in a `SecretStore`.
struct JSONRecord<Value: Codable & Sendable>: Sendable {
    let store: any SecretStore
    let name: String

    func load(default empty: Value) throws -> Value {
        guard let data = try store.read(name) else { return empty }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) throws { try store.write(name, try JSONEncoder().encode(value)) }
}
