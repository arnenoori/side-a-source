import Crypto
import Foundation

/// The idempotency records (`docs/remote/protocol.md`, Rules for every endpoint): one per `(device, key)` for 24 hours,
/// at most 1,000 a device, written as `started` before an effect and `done` with its response after. The Mac keeps them in
/// SQLite; the daemon keeps one 0600 JSON file, which the same rules fit at this volume. A `started` record left by an
/// earlier process is ambiguous: the repeat gets `outcome_unknown`, never a second execution.
public actor IdempotencyLedger {
    public static let maxAge: TimeInterval = 86_400
    public static let perDevice = 1_000
    public static let maxKey = 128

    public enum Lookup: Equatable, Sendable {
        case run
        case replay(status: Int, contentType: String?, body: Data)
        case mismatch
        case running
        case unknown
        case unavailable
    }

    struct Entry: Codable, Sendable {
        var method: String
        var path: String
        var bodyHash: Data
        var done: Bool
        var status: Int?
        var contentType: String?
        var response: Data?
        var created: TimeInterval
    }

    private var entries: [String: Entry] = [:]
    private var running: Set<String> = []
    private var waiting: [String: [UUID: CheckedContinuation<Bool, Never>]] = [:]
    private let record: JSONRecord<[String: Entry]>?

    public init(store: (any SecretStore)?) {
        guard let store else { record = nil; return }
        let record = JSONRecord<[String: Entry]>(store: store, name: "idempotency.json")
        self.record = record
        entries = (try? record.load(default: [:])) ?? [:]
    }

    private static func slot(_ device: String, _ key: String) -> String { device + "\n" + key }

    public func begin(device: String, key: String, method: String, path: String, body: Data, now: TimeInterval) -> Lookup {
        let hash = Data(SHA256.hash(data: body))
        let slot = Self.slot(device, key)
        if let entry = entries[slot], now - entry.created <= Self.maxAge {
            guard entry.method == method, entry.path == path, entry.bodyHash == hash else { return .mismatch }
            if entry.done, let status = entry.status { return .replay(status: status, contentType: entry.contentType, body: entry.response ?? Data()) }
            return running.contains(slot) ? .running : .unknown
        }
        entries[slot] = Entry(method: method, path: path, bodyHash: hash, done: false, created: now)
        guard persist() else { entries[slot] = nil; return .unavailable }
        running.insert(slot)
        return .run
    }

    public func finish(device: String, key: String, status: Int, contentType: String?, body: Data) {
        let slot = Self.slot(device, key)
        running.remove(slot)
        for waiter in (waiting.removeValue(forKey: slot) ?? [:]).values { waiter.resume(returning: true) }
        if status == 401 || status == 429 || status >= 500 || Self.wantsProof(status: status, body: body) {
            entries[slot] = nil
        } else if var entry = entries[slot] {
            entry.done = true; entry.status = status; entry.contentType = contentType; entry.response = body
            entries[slot] = entry
        }
        _ = persist()
    }

    /// Whether the call running under this key finished within `limit`; true at once when none is running.
    public func settled(device: String, key: String, within limit: Duration) async -> Bool {
        let slot = Self.slot(device, key)
        guard running.contains(slot) else { return true }
        let id = UUID()
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: limit) } catch { return }
            await self?.giveUp(slot, id)
        }
        let finished = await withCheckedContinuation { waiting[slot, default: [:]][id] = $0 }
        timeout.cancel()
        return finished
    }

    private func giveUp(_ slot: String, _ id: UUID) { waiting[slot]?.removeValue(forKey: id)?.resume(returning: false) }

    /// A refusal that a fresh signature can fix is not recorded, so re-signing and resending runs the call.
    static func wantsProof(status: Int, body: Data) -> Bool {
        guard status == 409 || status == 422,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let error = object["error"] as? [String: Any] else { return false }
        switch (status, error["code"] as? String) {
        case (409, "gate_changed"): return true
        case (422, "invalid_answer"): return (error["details"] as? [String: Any])?["reason"] as? String == "needs_confirm"
        default: return false
        }
    }

    public func forget(device: String) {
        entries = entries.filter { !$0.key.hasPrefix(device + "\n") }
        _ = persist()
    }

    public func trim(now: TimeInterval) {
        entries = entries.filter { now - $0.value.created <= Self.maxAge }
        var perDevice: [String: [(String, TimeInterval)]] = [:]
        for (slot, entry) in entries { perDevice[String(slot.split(separator: "\n").first ?? ""), default: []].append((slot, entry.created)) }
        for (_, list) in perDevice where list.count > Self.perDevice {
            for (slot, _) in list.sorted(by: { $0.1 < $1.1 }).prefix(list.count - Self.perDevice) { entries[slot] = nil }
        }
        _ = persist()
    }

    public func count(_ device: String) -> Int { entries.keys.filter { $0.hasPrefix(device + "\n") }.count }

    private func persist() -> Bool {
        guard let record else { return true }
        do { try record.save(entries); return true } catch { return false }
    }
}
