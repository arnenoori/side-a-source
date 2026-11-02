import CryptoKit
import Foundation
import Security
import SideACore

/// Remote's secrets: the TLS key the phone pins, the paired devices' token hashes and push keys, and the relay key. Never a file under `runtime/`,
/// which agents read and could write a hash into. Each build has its own service, so Side A Dev never sees release's.
struct RemoteKeychain: @unchecked Sendable {
    let service: String
    /// Tests use a throwaway keychain; the app uses the login keychain's default.
    let keychain: SecKeychain?

    /// Set only for the demo: devices and the relay key live in memory and there is no TLS key, so a demo never reads the login keychain.
    private let memory: Memory?

    init(service: String = (Bundle.main.bundleIdentifier ?? AppCopies.releaseID + ".dev") + ".remote", keychain: SecKeychain? = nil) {
        self.service = service; self.keychain = keychain; memory = nil
    }

    private init(memory: Memory) { service = "demo.sidea.remote"; keychain = nil; self.memory = memory }

    static func inMemory() -> RemoteKeychain { RemoteKeychain(memory: Memory()) }
    /// An in-memory keychain's reads so far, for tests that check nothing was read.
    var memoryReads: Int { memory?.reads ?? 0 }

    /// The login keychain; in Side A Dev only, the keychain file `SIDEA_REMOTE_KEYCHAIN` names, unlocked with
    /// `SIDEA_REMOTE_KEYCHAIN_PASSWORD`, so a live check of the real app never writes Remote's items into the login
    /// keychain. A file that isn't there stops the app rather than fall back to the login keychain.
    static func forApp(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> RemoteKeychain {
        guard !AppCopies.isRelease, let path = environment["SIDEA_REMOTE_KEYCHAIN"], !path.isEmpty else { return RemoteKeychain() }
        var keychain: SecKeychain?
        guard FileManager.default.fileExists(atPath: path), SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain else {
            fatalError("SIDEA_REMOTE_KEYCHAIN names \(path), which isn't a keychain file.")
        }
        let password = environment["SIDEA_REMOTE_KEYCHAIN_PASSWORD"] ?? ""
        SecKeychainUnlock(keychain, UInt32(password.utf8.count), password, true)
        return RemoteKeychain(keychain: keychain)
    }

    private final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: Data] = [:]
        private(set) var reads = 0
        subscript(account: String) -> Data? {
            get { lock.withLock { reads += 1; return stored[account] } }
            set { lock.withLock { stored[account] = newValue } }
        }
    }

    struct Failure: Error, LocalizedError {
        let status: OSStatus
        let what: String
        var errorDescription: String? {
            "\(what): \(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")"
        }
    }

    /// Adding names the keychain to write to; every other call searches it.
    private func scoped(_ query: [CFString: Any], adding: Bool = false) -> CFDictionary {
        var query = query
        if let keychain { query[adding ? kSecUseKeychain : kSecMatchSearchList] = adding ? keychain : [keychain] }
        // A certificate has no access of its own; only keys and passwords do.
        if adding, query[kSecClass] as? String != kSecClassCertificate as String, let access = Self.openAccess(keychain) { query[kSecAttrAccess] = access }
        return query as CFDictionary
    }

    /// A named keychain is only ever a throwaway one (Side A Dev's SIDEA_REMOTE_KEYCHAIN, tests): its items let any app
    /// use them. By default an item trusts the app that made it, and an ad hoc signed build is known by its cdhash,
    /// so every rebuild of Side A Dev would ask for the keychain's password. Only at creation: changing an existing
    /// item's access asks too. The login keychain keeps the default, where a Developer ID build is known by its team
    /// and an update never asks (see `keyAccess`).
    private static func openAccess(_ keychain: SecKeychain?) -> SecAccess? {
        guard keychain != nil else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("Side A Remote" as CFString, [] as CFArray, &access) == errSecSuccess, let access else { return nil }
        var list: CFArray?
        SecAccessCopyACLList(access, &list)
        for acl in (list as? [SecACL]) ?? [] {
            // Who may change the access stays as it is.
            guard !((SecACLCopyAuthorizations(acl) as? [String]) ?? []).contains(kSecACLAuthorizationChangeACL as String) else { continue }
            var apps: CFArray?, description: CFString?, prompt = SecKeychainPromptSelector()
            SecACLCopyContents(acl, &apps, &description, &prompt)
            SecACLSetContents(acl, nil, description ?? "Side A Remote" as CFString, [])
        }
        return access
    }

    // MARK: Devices

    /// nil when there is no item yet. Throws when one exists but can't be read: Remote then accepts no device
    /// and never replaces the item silently.
    func readDevices() throws -> Data? { try read("devices", what: "Paired devices") }
    func writeDevices(_ data: Data) throws { try write(data, "devices", label: "Side A Remote devices", what: "Paired devices") }
    func deleteDevices() { delete("devices") }

    // MARK: Relay install key

    /// The Ed25519 key that signs every request to the push relay; its hash is the install id. Made on first use.
    func installKey(create: Bool = true) throws -> Curve25519.Signing.PrivateKey? {
        if let data = try read("install", what: "The relay key") {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        guard create else { return nil }
        let key = Curve25519.Signing.PrivateKey()
        try write(key.rawRepresentation, "install", label: "Side A Remote relay key", what: "The relay key")
        return key
    }

    func deleteInstallKey() { delete("install") }

    // MARK: Items

    private func read(_ account: String, what: String) throws -> Data? {
        if let memory { return memory[account] }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(scoped([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                                 kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]), &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status, what: "\(what) couldn't be read") }
        return data
    }

    private func write(_ data: Data, _ account: String, label: String, what: String) throws {
        if let memory { memory[account] = data; return }
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let status = SecItemUpdate(scoped(item), [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = item
            add[kSecValueData] = data
            add[kSecAttrLabel] = label
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(scoped(add, adding: true), nil)
            guard added == errSecSuccess else { throw Failure(status: added, what: "\(what) couldn't be saved") }
        } else if status != errSecSuccess {
            throw Failure(status: status, what: "\(what) couldn't be saved")
        }
    }

    private func delete(_ account: String) {
        if let memory { memory[account] = nil; return }
        SecItemDelete(scoped([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]))
    }

    // MARK: Identity

    struct Identity: @unchecked Sendable {
        let identity: SecIdentity
        /// SHA-256 of the key's SubjectPublicKeyInfo: what the phone pins.
        let spkiHash: Data
    }

    private var tag: Data { Data((service + ".identity").utf8) }

    /// The TLS identity, made on first use: a P-256 key that never leaves the Keychain and a ten-year self-signed
    /// certificate. Replacing it means every phone pairs again, so a read failure throws instead of making a new one.
    func identity(create: Bool = true) throws -> Identity? {
        guard memory == nil else { return nil }
        if let found = try find() { return found }
        guard create else { return nil }
        return try make()
    }

    func deleteIdentity() {
        guard memory == nil else { return }
        var result: CFTypeRef?
        if SecItemCopyMatching(scoped([kSecClass: kSecClassIdentity, kSecAttrApplicationTag: tag, kSecReturnRef: true,
                                       kSecMatchLimit: kSecMatchLimitOne]), &result) == errSecSuccess, let result {
            var certificate: SecCertificate?
            if SecIdentityCopyCertificate(result as! SecIdentity, &certificate) == errSecSuccess, let certificate {
                SecItemDelete(scoped([kSecClass: kSecClassCertificate, kSecValueRef: certificate]))
            }
        }
        SecItemDelete(scoped([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag]))
    }

    /// What the TLS key's use is tied to, for Copy Diagnostics: "any app" (a named keychain), or the partitions macOS
    /// checks, `teamid:…` for a Developer ID build (stable across updates) or `cdhash:…` for an ad hoc one (changes with
    /// every build, so the next one asks). Reading an item's access never asks.
    func keyAccess() -> String {
        guard memory == nil else { return "in memory" }
        var result: CFTypeRef?
        guard SecItemCopyMatching(scoped([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                                          kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitOne]), &result) == errSecSuccess, let result else { return "no key" }
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(result as! SecKeychainItem, &access) == errSecSuccess, let access else { return "unreadable" }
        var list: CFArray?
        SecAccessCopyACLList(access, &list)
        var parts: [String] = []
        for acl in (list as? [SecACL]) ?? [] {
            let authorizations = (SecACLCopyAuthorizations(acl) as? [String]) ?? []
            var apps: CFArray?, description: CFString?, prompt = SecKeychainPromptSelector()
            SecACLCopyContents(acl, &apps, &description, &prompt)
            if authorizations.contains(kSecACLAuthorizationPartitionID as String) {
                // The description is a hex-encoded plist with the partition list.
                let hex = (description as String?) ?? ""
                let bytes = stride(from: 0, to: hex.count - 1, by: 2).compactMap { UInt8(hex.dropFirst($0).prefix(2), radix: 16) }
                let plist = try? PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String: Any]
                parts += (plist?["Partitions"] as? [String]) ?? ["partitions unreadable"]
            } else if authorizations.contains(kSecACLAuthorizationSign as String) {
                parts.append(apps == nil ? "any app" : "\((apps as? [Any])?.count ?? 0) app(s)")
            }
        }
        return parts.joined(separator: ", ")
    }

    /// Whether the identity's key signs now; blocks while macOS asks the user about it.
    static func signs(_ identity: Identity) -> Bool {
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity.identity, &key) == errSecSuccess, let key else { return false }
        return SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data("Side A".utf8) as CFData, nil) != nil
    }

    /// Found by the key's tag: the Keychain names a certificate after its subject, whatever label it was added with.
    private func find() throws -> Identity? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(scoped([kSecClass: kSecClassIdentity, kSecAttrApplicationTag: tag, kSecReturnRef: true,
                                                 kSecMatchLimit: kSecMatchLimitOne]), &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let result, CFGetTypeID(result) == SecIdentityGetTypeID() else {
            throw Failure(status: status, what: "Side A's security key couldn't be read")
        }
        let identity = result as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate, let key = SecCertificateCopyKey(certificate),
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            throw Failure(status: errSecInvalidKeyRef, what: "Side A's security key couldn't be read")
        }
        return Identity(identity: identity, spkiHash: SelfSignedCertificate.spkiHash(publicKey: point))
    }

    private func make() throws -> Identity {
        var error: Unmanaged<CFError>?
        var attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256, kSecAttrLabel: "Side A Remote",
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true, kSecAttrApplicationTag: tag, kSecAttrIsExtractable: false] as [CFString: Any],
        ]
        if let keychain { attributes[kSecUseKeychain] = keychain }
        if let access = Self.openAccess(keychain) { attributes[kSecAttrAccess] = access }
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error), let publicKey = SecKeyCopyPublicKey(key),
              let point = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw Failure(status: errSecParam, what: "Side A couldn't make its security key (\(error?.takeRetainedValue().localizedDescription ?? "unknown"))")
        }
        var serial = Secret.bytes(16)
        serial[0] &= 0x7F
        let now = Date()
        let tbs = SelfSignedCertificate.tbs(publicKey: point, serial: Data(serial), name: "Side A on \(Host.current().localizedName ?? "this Mac")",
                                            from: now.addingTimeInterval(-86_400), until: now.addingTimeInterval(10 * 365 * 86_400))
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data?,
              let certificate = SecCertificateCreateWithData(nil, SelfSignedCertificate.certificate(tbs: tbs, signature: signature) as CFData) else {
            deleteIdentity()
            throw Failure(status: errSecParam, what: "Side A couldn't sign its certificate")
        }
        let added = SecItemAdd(scoped([kSecClass: kSecClassCertificate, kSecValueRef: certificate], adding: true), nil)
        guard added == errSecSuccess else {
            deleteIdentity()
            throw Failure(status: added, what: "Side A couldn't save its certificate")
        }
        guard let found = try find() else { throw Failure(status: errSecItemNotFound, what: "Side A's security key couldn't be read") }
        return found
    }
}
