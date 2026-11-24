import Foundation

/// A mutation the phone queues for the Mac, and the route the Mac serves it at: one place for its method, its path and
/// what its id names, so the phone's outbox and engine, a notification action and the Mac's server build and read the
/// same strings.
public struct QueuedRoute: Sendable, Equatable {
    /// What the route's id names. Items for one subject go to the Mac in order.
    public enum Subject: String, Sendable, CaseIterable {
        case request, session

        /// The path's collection: `/v1/requests/{rid}/…`, `/v1/sessions/{id}/…`.
        public var collection: String { self == .request ? "requests" : "sessions" }
        /// The name the Mac's route pattern gives the id.
        public var placeholder: String { self == .request ? "rid" : "id" }
    }

    public let method: String
    public let subject: Subject
    /// The last path component.
    public let action: String

    /// As the Mac registers it, without the leading slash: `v1/requests/{rid}/answer`.
    public var pattern: String { "v1/\(subject.collection)/{\(subject.placeholder)}/\(action)" }

    /// The path a client sends, for the request or session `id`.
    public func path(_ id: String) -> String { "/v1/\(subject.collection)/\(id)/\(action)" }

    /// The id in `path` when it is this route's, whatever the method: the part after the collection, read as written.
    public func id(inPath path: String) -> String? {
        let parts = path.split(separator: "/")
        return parts.count == 4 && parts[1] == subject.collection && parts[3] == action ? String(parts[2]) : nil
    }

    /// Whether a request is a call of this route: the Mac's own path components, as `HTTPRequest.path` holds them.
    public func matches(method: String, components: [String]) -> Bool {
        method == self.method && components.count == 4 && components[0] == "v1" && components[1] == subject.collection
            && components[3] == action
    }
}

public enum QueuedRoutes {
    public static let answer = QueuedRoute(method: "POST", subject: .request, action: "answer")
    public static let reply = QueuedRoute(method: "POST", subject: .session, action: "reply")
    public static let interrupt = QueuedRoute(method: "POST", subject: .session, action: "interrupt")
    public static let takeBack = QueuedRoute(method: "DELETE", subject: .session, action: "mail")

    /// What a queued item with this path acts on, so items for one session or request go in order and a retrying one holds
    /// back only those: `request:<rid>`, `session:<id>`, or the path itself for anything else. The id is as written in the
    /// path, which is how rows already queued hold it.
    public static func target(ofPath path: String) -> String {
        let parts = path.split(separator: "/")
        if parts.count >= 3, let subject = QueuedRoute.Subject.allCases.first(where: { $0.collection == parts[1] }) {
            return "\(subject.rawValue):\(parts[2])"
        }
        return path
    }

    /// The request an answer's path is for, decoded.
    public static func answering(path: String) -> String? {
        answer.id(inPath: path)?.removingPercentEncoding
    }
}
