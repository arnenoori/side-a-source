import Foundation
import Security

public enum SharedStorage {
    public static let appGroup = Bundle.main.object(forInfoDictionaryKey: "SideAAppGroup") as? String ?? "group.com.arnenoori.sidea.remote"

    /// The one settings store the app, its widgets and its extensions all read.
    nonisolated(unsafe) public static let defaults = UserDefaults(suiteName: appGroup) ?? .standard

    public static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    public static var database: URL? { container?.appendingPathComponent("shared.sqlite") }
}

public struct SharedKeychain: Sendable {
    public static let shared = SharedKeychain()

    private let service: String

    /// A different `service` is a separate set of items in the same group: a test's own, never the app's.
    public init(service: String? = nil) { self.service = service ?? "com.arnenoori.sidea.remote" }

    /// "<team prefix>com.arnenoori.sidea.remote.shared", from the Info.plist; nil in a build without
    /// a team, where the app's own keychain stands in.
    private let group: String? = {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "SideAKeychainGroup") as? String,
              !group.hasPrefix(".") else { return nil }
        return group
    }()

    public func data(_ account: String) -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Nil deletes. Readable after first unlock, so a notification action can answer on a locked phone.
    @discardableResult
    public func set(_ data: Data?, for account: String) -> Bool {
        let query = base(account)
        SecItemDelete(query as CFDictionary)
        guard let data else { return true }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private func base(_ account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }
}
