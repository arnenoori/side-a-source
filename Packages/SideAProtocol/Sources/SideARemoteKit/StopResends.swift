import Foundation
import SideAProtocol

/// Interrupt and Resend on a Mac without `interrupt.resend`: the phone sends again what that stop gave back. Only that
/// stop's give-back goes; a later plain Stop's is the person's to send or not. Per session it is either idle or pressed.
public struct StopResends: Sendable {
    /// The stop's own give-back comes with its answer, or just after it.
    public static let afterAnswer: Duration = .seconds(5)
    /// A give-back this long after the press can't be that stop's.
    public static let within: TimeInterval = 30

    private var pressed: [SessionKey: Date] = [:]

    public init() {}

    public func isPressed(_ session: SessionKey) -> Bool { pressed[session] != nil }

    public mutating func press(_ session: SessionKey, at: Date) { pressed[session] = at }

    /// Another send or stop on the session: its give-back is no longer this press's.
    public mutating func cancel(_ session: SessionKey) { pressed[session] = nil }

    /// `afterAnswer` past the stop's answer; a later press on the session is left alone.
    public mutating func answered(_ session: SessionKey, pressedAt: Date) {
        if pressed[session] == pressedAt { pressed[session] = nil }
    }

    public mutating func gaveBack(_ session: SessionKey, now: Date = .now) -> Bool {
        guard let at = pressed.removeValue(forKey: session) else { return false }
        return now.timeIntervalSince(at) < Self.within
    }
}
