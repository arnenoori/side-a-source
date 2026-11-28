import Foundation
import SideAProtocol

/// What a Mac has under Settings > Remote > Computers (Accept Sessions, Include Ignored .env Files, Standby), for
/// `sidead config`. One 0600 file in the state folder (`moves-settings.json`), read whenever one of them is needed, so a
/// change made while the daemon runs applies to the next move without telling it.
public struct MoveSettings: Codable, Sendable, Equatable {
    /// Sessions and checkpoints sent from the computers linked to this one are taken.
    public var accepts = true
    /// A project's ignored `.env` files go with a session this computer sends.
    public var includesEnv = false
    /// The linked computer this one's checkpoints go to (its host id), or nil for none.
    public var standby: String?

    public init(accepts: Bool = true, includesEnv: Bool = false, standby: String? = nil) {
        self.accepts = accepts; self.includesEnv = includesEnv; self.standby = standby
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accepts = try values.decodeIfPresent(Bool.self, forKey: .accepts) ?? true
        includesEnv = try values.decodeIfPresent(Bool.self, forKey: .includesEnv) ?? false
        standby = try values.decodeIfPresent(String.self, forKey: .standby)
    }

    static let file = "moves-settings.json"

    /// What is kept, or the defaults when nothing is. A file that can't be read takes nothing in and sends nothing away,
    /// so a switch turned off is never read as on.
    static func load(_ store: any SecretStore) -> MoveSettings {
        do { return try JSONRecord<MoveSettings>(store: store, name: file).load(default: MoveSettings()) } catch {
            DaemonLog.line("couldn't read \(file), so sessions aren't accepted and nothing goes to a standby: \(error)")
            return MoveSettings(accepts: false)
        }
    }

    static func save(_ settings: MoveSettings, to store: any SecretStore) throws {
        try JSONRecord<MoveSettings>(store: store, name: file).save(settings)
    }

    /// The names `sidead config` takes.
    static let keys = ["accept-sessions", "include-env", "standby"]

    /// One change by name, as `sidead config KEY VALUE` says it. `computers` resolves a standby given by name.
    func changed(_ key: String, to value: String, computers: [LinkedComputer]) throws -> MoveSettings {
        var next = self
        let word = value.trimmingCharacters(in: .whitespaces)
        func flag() throws -> Bool {
            switch word.lowercased() {
            case "on", "yes", "true": return true
            case "off", "no", "false": return false
            default: throw MoveFailure.refused("Say on or off.")
            }
        }
        switch key {
        case "accept-sessions": next.accepts = try flag()
        case "include-env": next.includesEnv = try flag()
        case "standby":
            if ["off", "none", ""].contains(word.lowercased()) {
                next.standby = nil
            } else {
                let found = computers.first { $0.id == word } ?? computers.first { $0.name.caseInsensitiveCompare(word) == .orderedSame }
                    ?? computers.first { $0.id.hasPrefix(word.lowercased()) }
                guard let found else { throw MoveFailure.refused("No linked computer is called \(word).") }
                next.standby = found.id
            }
        default:
            throw MoveFailure.refused("There's no setting called \(key). The settings are \(Self.keys.joined(separator: ", ")).")
        }
        return next
    }

    /// The lines `sidead config` prints.
    func lines(computers: [LinkedComputer]) -> [[String: String]] {
        let standby = standby.map { id in computers.first { $0.id == id }?.name ?? "a computer that isn't linked any more" } ?? "off"
        return [["key": "accept-sessions", "value": accepts ? "on" : "off"], ["key": "include-env", "value": includesEnv ? "on" : "off"],
                ["key": "standby", "value": standby]]
    }
}
