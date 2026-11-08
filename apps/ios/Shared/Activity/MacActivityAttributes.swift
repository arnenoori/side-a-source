import ActivityKit
import Foundation

/// One Live Activity per Mac. The name is what the
/// relay's push-to-start sends as `attributes-type`, so it must not change. Everything here reaches
/// Apple and the relay in plaintext: counts, times and opaque ids, never words.
public struct MacActivityAttributes: ActivityAttributes {
    /// `base64url(SHA-256("SideA macID v1\n" + installID)[0..<12])`, never the Mac's name.
    public let macID: String

    public struct ContentState: Codable, Hashable, Sendable {
        public var working: Int
        public var waiting: Int
        /// A random request id; its words come from the push cache.
        public var topRequest: String?
        /// ActivityKit's default date coding (seconds since 2001), as the Mac sends it.
        public var soonestReset: Date?
        public var tightestPercent: Int?

        public init(working: Int, waiting: Int, topRequest: String? = nil, soonestReset: Date? = nil, tightestPercent: Int? = nil) {
            self.working = working; self.waiting = waiting; self.topRequest = topRequest
            self.soonestReset = soonestReset; self.tightestPercent = tightestPercent
        }
    }

    public init(macID: String) { self.macID = macID }
}
