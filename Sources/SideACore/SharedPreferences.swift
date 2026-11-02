import CoreFoundation
import Foundation

public enum PreferenceKind: Sendable { case bool, int, double, string }

public enum PreferenceValue: Equatable, Sendable {
    case bool(Bool), int(Int), double(Double), string(String)

    /// Typed by what the key holds: a file edited by hand or another version can't change a setting's type.
    public init?(_ raw: Any?, as kind: PreferenceKind) {
        switch kind {
        case .string:
            guard let text = raw as? String else { return nil }
            self = .string(text)
        case .bool:
            guard let number = raw as? NSNumber, number == 0 || number == 1 else { return nil }
            self = .bool(number.boolValue)
        case .int:
            guard let number = raw as? NSNumber, !Self.isBoolean(number), number.doubleValue == number.doubleValue.rounded(),
                  abs(number.doubleValue) < 1e15 else { return nil }
            self = .int(number.intValue)
        case .double:
            guard let number = raw as? NSNumber, !Self.isBoolean(number), number.doubleValue.isFinite else { return nil }
            self = .double(number.doubleValue)
        }
    }

    public var raw: Any {
        switch self {
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }
}

/// Settings every copy of Side A shares, each with the time it was set. Everything is kept as read, so
/// fields and keys a newer version wrote survive being saved by this one.
public struct SharedPreferences {
    public static let version = 1
    /// A clock this far ahead would win every later change, so its entries don't count.
    private static let clockSlack = 86_400.0

    public enum Decoded {
        case file(SharedPreferences)
        case corrupt
        /// An incompatible format: neither applied nor overwritten.
        case newer
    }

    public struct Entry {
        public let value: Any
        public let at: Double
        public let by: String?
        public let imported: Bool
    }

    private var top: [String: Any] = [:]
    private var values: [String: Any] = [:]

    public init() {}

    public static func decode(_ data: Data) -> Decoded {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = object["values"] as? [String: Any] else { return .corrupt }
        if let version = object["version"] as? Int, version > Self.version { return .newer }
        var file = SharedPreferences()
        file.top = object
        file.top["values"] = nil
        file.values = values
        return .file(file)
    }

    public func encoded() -> Data {
        var object = top
        object["version"] = Self.version
        object["values"] = values
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    public func entry(_ key: String, now: Double = Date().timeIntervalSince1970) -> Entry? {
        guard let raw = values[key] as? [String: Any], let value = raw["value"],
              let at = (raw["at"] as? NSNumber)?.doubleValue, at.isFinite, at > 0, at <= now + Self.clockSlack else { return nil }
        return Entry(value: value, at: at, by: raw["by"] as? String, imported: raw["imported"] as? Bool ?? false)
    }

    /// A change made here. It always passes the entry it replaces, even when another Mac's clock ran ahead.
    public mutating func stamp(_ key: String, _ value: PreferenceValue, by: String?, now: Double = Date().timeIntervalSince1970) {
        var raw = values[key] as? [String: Any] ?? [:]
        let previous = entry(key, now: now)?.at ?? 0
        raw["value"] = value.raw
        raw["at"] = max(now, previous + 0.001)
        raw["by"] = by
        raw["imported"] = nil
        values[key] = raw
    }

    /// A value from before there were timestamps. It fills a gap and loses to any change made since.
    public mutating func adopt(_ key: String, _ value: PreferenceValue, at: Double, by: String?, now: Double = Date().timeIntervalSince1970) {
        guard entry(key, now: now) == nil else { return }
        var raw: [String: Any] = ["value": value.raw, "at": min(max(at, 1), now), "imported": true]
        raw["by"] = by
        values[key] = raw
    }

    /// Newest wins per key. A real change beats an imported value, whatever the times; `by` settles an exact
    /// tie the same way on every Mac.
    public mutating func merge(_ other: SharedPreferences, now: Double = Date().timeIntervalSince1970) {
        for (key, raw) in other.values {
            guard let theirs = other.entry(key, now: now) else {
                if values[key] == nil { values[key] = raw }
                continue
            }
            guard let mine = entry(key, now: now) else { values[key] = raw; continue }
            if Self.wins(theirs, over: mine) { values[key] = raw }
        }
    }

    /// Fields only another version knows about, without replacing anything this file holds.
    public mutating func keepUnknownFields(of other: SharedPreferences) {
        for (key, value) in other.top where top[key] == nil { top[key] = value }
    }

    /// What may leave this Mac: only the named keys, and no top-level field.
    public func exported(_ keys: some Sequence<String>) -> SharedPreferences {
        var copy = SharedPreferences()
        for key in keys { if let raw = values[key] { copy.values[key] = raw } }
        return copy
    }

    private static func wins(_ theirs: Entry, over mine: Entry) -> Bool {
        if theirs.imported != mine.imported { return mine.imported }
        if theirs.at != mine.at { return theirs.at > mine.at }
        return (theirs.by ?? "") > (mine.by ?? "")
    }
}
