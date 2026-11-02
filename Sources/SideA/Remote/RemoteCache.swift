import Foundation

/// Answers the phone's list routes reuse for a few seconds: the bridge and git are subprocesses, and a phone asks for
/// the same list each time a screen opens. Requests that arrive together share one run; a failed run isn't kept.
actor RemoteCache {
    private struct Entry { let task: Task<any Sendable, Error>; let at: Date; let generation: Int; let serial: Int }
    private var entries: [String: Entry] = [:]
    private var serial = 0

    /// The value made under this key within `ttl` seconds, unless the generation it was made in has passed.
    func value<T: Sendable>(_ key: String, ttl: TimeInterval, generation: Int = 0, _ make: @escaping @Sendable () async throws -> T) async throws -> T {
        let now = Date()
        let entry: Entry
        if let found = entries[key], found.generation == generation, now.timeIntervalSince(found.at) < ttl {
            entry = found
        } else {
            serial += 1
            entry = Entry(task: Task { try await make() }, at: now, generation: generation, serial: serial)
            entries = entries.filter { now.timeIntervalSince($0.value.at) < 600 }
            entries[key] = entry
        }
        do {
            guard let value = try await entry.task.value as? T else { throw CancellationError() }
            return value
        } catch {
            if entries[key]?.serial == entry.serial { entries[key] = nil }
            throw error
        }
    }

    func clear() { entries = [:] }
}
