import Foundation

public extension Capability {
    /// This computer keeps checkpoints of another computer's sessions and can continue one as a copy.
    static let standby = Self(rawValue: "standby")
}

/// A checkpoint of a session that is still running on the computer that sends it (`POST /v1/standby`). The
/// receiver keeps the newest one per conversation and runs nothing. The files follow as a move's do, under
/// `/v1/standby/{id}/parts/{name}/{index}`, and `POST /v1/standby/{id}/keep` (a `MoveStage`) checks and keeps them.
public struct StandbyOffer: Codable, Hashable, Sendable {
    public let id: String
    public let conversationID: String
    public let agent: AgentProvider
    public let project: String
    public let title: String?
    public let commits: [String]
    public let origin: String?
    public let model: String?
    public let effort: String?
    public let permissionMode: PermissionMode?
    public let from: MacInfo
    /// When the checkpoint was taken on the sender.
    public let at: Timestamp
    public init(id: String, conversationID: String, agent: AgentProvider, project: String, title: String? = nil, commits: [String], origin: String? = nil,
                model: String? = nil, effort: String? = nil, permissionMode: PermissionMode? = nil, from: MacInfo, at: Timestamp) {
        self.id = id; self.conversationID = conversationID; self.agent = agent; self.project = project; self.title = title
        self.commits = commits; self.origin = origin; self.model = model; self.effort = effort
        self.permissionMode = permissionMode; self.from = from; self.at = at
    }
}

/// A checkpoint this host holds for another computer (`GET /v1/standby`). `POST /v1/standby/{conversationID}/copy`
/// continues it here as a copy: a fork with a new conversation id, because the computer it came from cannot be
/// told and may still be running the original.
public struct StandbyCopy: Codable, Hashable, Sendable, Identifiable {
    public var id: String { conversationID }
    public let conversationID: String
    public let agent: AgentProvider
    public let title: String?
    public let project: String?
    /// The computer the session runs on: its host id and the name to show.
    public let computer: String
    public let computerName: String
    public let at: Timestamp
    public init(conversationID: String, agent: AgentProvider, title: String? = nil, project: String? = nil, computer: String, computerName: String, at: Timestamp) {
        self.conversationID = conversationID; self.agent = agent; self.title = title; self.project = project
        self.computer = computer; self.computerName = computerName; self.at = at
    }
}

public struct StandbyList: Codable, Hashable, Sendable {
    public let copies: [StandbyCopy]
    public init(copies: [StandbyCopy]) { self.copies = copies }
}
