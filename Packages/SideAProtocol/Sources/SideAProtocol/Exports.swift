import Foundation

public typealias Timestamp = Double           // seconds since 1970
public typealias SessionKey = String
public typealias RequestID = String           // lowercased UUID

/// The protocol this package speaks, sent as `X-SideA-Protocol` and in `Hello`.
public enum ProtocolVersion {
    public static let current = 1
}

/// An enum that may grow: unknown values decode and round-trip unchanged.
public protocol OpenEnum: RawRepresentable, Codable, Hashable, Comparable, Sendable where RawValue == String {
    init(rawValue: String)
}
public extension OpenEnum {
    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Opaque pagination cursor. Clients store and send it back; they never parse it.
public struct Cursor: Codable, Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(from decoder: Decoder) throws { raw = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(raw) }
}

/// A set that encodes as a sorted array, so the same value always gives the same bytes.
@propertyWrapper
public struct Sorted<Element: Comparable & Hashable & Codable & Sendable>: Codable, Hashable, Sendable {
    public var wrappedValue: Set<Element>
    public init(wrappedValue: Set<Element>) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws { wrappedValue = Set(try decoder.singleValueContainer().decode([Element].self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(wrappedValue.sorted()) }
}

/// Keys for objects whose shape depends on a tag (`kind`, `type`).
struct AnyKey: CodingKey {
    let stringValue: String
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where K == AnyKey {
    func value<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T { try decode(T.self, forKey: AnyKey(key)) }
    func optional<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T? { try decodeIfPresent(T.self, forKey: AnyKey(key)) }
}

extension KeyedEncodingContainer where K == AnyKey {
    mutating func put<T: Encodable>(_ value: T, _ key: String) throws { try encode(value, forKey: AnyKey(key)) }
    mutating func put<T: Encodable>(_ value: T?, _ key: String) throws { try encodeIfPresent(value, forKey: AnyKey(key)) }
}
