import Foundation
import Security

/// The only call Side A's privileged helper answers. The reply is whether sleep is disabled afterwards.
@objc public protocol KeepAwakeHelping {
    func setLidSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool) -> Void)
}

public enum KeepAwakeHelper {
    public static let label = "com.sidea.keepawake"
    public static let plistName = label + ".plist"
    public static let identifier = label
    public static let clients = ["com.arnenoori.sidea", "com.arnenoori.sidea.dev"]
    /// Outlives the helper and a restart, so a later launch knows the setting is its own to give back.
    public static let stateFile = "/private/var/db/com.sidea.keepawake"
    public static let pmset = "/usr/bin/pmset"

    public static func command(_ disabled: Bool) -> [String] { ["-a", "disablesleep", disabled ? "1" : "0"] }

    /// `pmset -g` lists SleepDisabled under its system-wide settings only while it is set.
    public static func sleepDisabled(pmsetOutput: String) -> Bool {
        pmsetOutput.split(separator: "\n").contains { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            return words.count == 2 && words[0] == "SleepDisabled" && Int(words[1]).map { $0 != 0 } == true
        }
    }

    public static func validTeam(_ team: String) -> Bool {
        team.count == 10 && team.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// An ad-hoc build has no team, and then nothing can prove who is calling, so nothing may.
    public static func clientRequirement(team: String?) -> String? {
        guard let team, validTeam(team) else { return nil }
        let identifiers = clients.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        // Developer ID only: a development-signed copy can carry get-task-allow, which lets other processes drive it.
        return "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"\(team)\" and (\(identifiers))"
    }

    public static func helperRequirement(team: String?) -> String? {
        guard let team, validTeam(team) else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
    }

    public static func teamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// A short handover after a disconnect lets an update's relaunch take over without the Mac sleeping in between.
public struct LidSleepState: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case disable, restore }

    public static let handover: TimeInterval = 30
    public static let idleExit: TimeInterval = 10

    public private(set) var owned: Bool
    public private(set) var connected: Set<Int> = []
    public private(set) var asking: Set<Int> = []
    public private(set) var restoreAt: Double?
    private var quietSince: Double?

    public init(owned: Bool, now: Double) {
        self.owned = owned
        quietSince = now
    }

    public mutating func connect(_ client: Int) {
        connected.insert(client)
        quietSince = nil
    }

    public mutating func request(_ client: Int, disabled: Bool, systemDisabled: Bool) -> Action? {
        if disabled {
            asking.insert(client)
            restoreAt = nil
            return systemDisabled ? nil : .disable
        }
        asking.remove(client)
        return asking.isEmpty && owned ? .restore : nil
    }

    public mutating func disconnect(_ client: Int, now: Double) {
        connected.remove(client)
        if asking.remove(client) != nil, asking.isEmpty, owned { restoreAt = now + Self.handover }
        if connected.isEmpty { quietSince = now }
    }

    public func tick(now: Double) -> Action? {
        guard asking.isEmpty, owned else { return nil }
        if let restoreAt, now < restoreAt { return nil }
        return .restore
    }

    public mutating func applied(_ action: Action, success: Bool) {
        guard success else { return }
        switch action {
        case .disable: owned = true
        case .restore: owned = false; restoreAt = nil
        }
    }

    public func shouldExit(now: Double) -> Bool {
        connected.isEmpty && !owned && restoreAt == nil && quietSince.map { now - $0 >= Self.idleExit } == true
    }
}
