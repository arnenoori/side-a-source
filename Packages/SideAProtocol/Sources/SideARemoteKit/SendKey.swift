import Foundation

/// The Idempotency-Key for a call sent from a screen until it is answered, as a handoff or a restart is. The same body sent
/// again after no answer goes under the same key, so the Mac answers from the first attempt if that one landed. Once the
/// Mac has answered, its record keeps that answer for the key, so the key is spent; and a changed body under it would be
/// refused as a mismatch.
public struct SendKey<Body: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var value: String
    private var body: Body?

    public init(_ value: String = Self.fresh()) { self.value = value }

    public static func fresh() -> String { UUID().uuidString.lowercased() }

    public mutating func sending(_ body: Body, fresh: String = Self.fresh()) -> String {
        if let sent = self.body, sent != body { value = fresh }
        self.body = body
        return value
    }

    public mutating func answered(fresh: String = Self.fresh()) {
        value = fresh
        body = nil
    }
}
