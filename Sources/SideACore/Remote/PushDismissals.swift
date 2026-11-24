import Foundation

/// Which phones a request's "Answered" push goes to: those that were sent its notification, less the one that answered
/// (its app, action or Live Activity already took the notification away). A phone that never showed the request, because
/// that kind is off or it was watching the session, would otherwise get an "Answered" notification out of nothing.
public struct PushDismissals: Sendable {
    public static let kept = 512
    private var alerted: [String: Set<String>] = [:]
    private var order: [String] = []

    public init() {}

    /// Every collapse id and the devices it was sent to, oldest first.
    public var all: [(collapse: String, devices: [String])] { order.compactMap { id in alerted[id].map { (id, $0.sorted()) } } }

    /// A request's notification went to these devices, under this collapse id.
    public mutating func sent(_ collapse: String, to devices: [String]) {
        guard !devices.isEmpty else { return }
        if alerted[collapse] == nil {
            order.append(collapse)
            if order.count > Self.kept { alerted[order.removeFirst()] = nil }
        }
        alerted[collapse, default: []].formUnion(devices)
    }

    public func showing(_ collapse: String) -> [String] { alerted[collapse].map { $0.sorted() } ?? [] }

    /// The devices to clear it on, once; nil `answeredBy` when no phone answered it.
    public mutating func settled(_ collapse: String, answeredBy device: String?) -> [String] {
        guard let devices = alerted.removeValue(forKey: collapse) else { return [] }
        order.removeAll { $0 == collapse }
        return devices.subtracting(device.map { [$0] } ?? []).sorted()
    }
}
