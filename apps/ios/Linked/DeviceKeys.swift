import Foundation
import LocalAuthentication
import Security
import SideAProtocol
import SideARemoteShared

/// The phone's two Secure Enclave keys for one Mac (H1). The Mac requires a signature from one of them for anything
/// past a Lock Screen allow, so a token alone can't approve, open the terminal or type while a request waits.
/// - `confirm` signs only after Face ID (`.biometryCurrentSet`): biometric requests, the terminal, keys.
/// - `unlock` signs silently, but only while the phone is unlocked: allows behind an unlock gate.
nonisolated enum DeviceKeys {
    typealias Signer = ConfirmSignature.Signer

    /// Creates both keys for `macID` and returns their public halves (base64url X9.63). They wait beside the keys in
    /// use until `promote(for:)`, so a Pair Again that fails or is cancelled leaves the pairing it would have replaced
    /// signing as before. Nil when the Secure Enclave won't make them; pairing then goes ahead without, and the Mac
    /// allows only Lock Screen actions.
    static func create(for macID: String) -> (confirm: String, unlock: String)? {
        delete(for: macID, pending: true)
        guard let confirm = make(.confirm, macID: macID), let unlock = make(.unlock, macID: macID) else {
            delete(for: macID, pending: true)
            return nil
        }
        #if targetEnvironment(simulator)
        RemoteLog.log(.pairing, "device keys made (simulator keychain)")
        #else
        RemoteLog.log(.pairing, "device keys made (Secure Enclave)")
        #endif
        return (confirm, unlock)
    }

    /// The keys `create(for:)` made become the ones that sign for `macID`, once the pairing that sent them is saved.
    static func promote(for macID: String) {
        delete(for: macID, pending: false)
        for signer in [Signer.confirm, .unlock] {
            let status = SecItemUpdate(query(tag(signer, macID, pending: true)) as CFDictionary,
                                       [kSecAttrApplicationTag as String: tag(signer, macID, pending: false)] as CFDictionary)
            if status != errSecSuccess { RemoteLog.error(.pairing, "\(signer == .confirm ? "Face ID" : "unlock") key not kept: \(status)") }
        }
    }

    static func delete(for macID: String) {
        delete(for: macID, pending: false)
        delete(for: macID, pending: true)
    }

    private static func delete(for macID: String, pending: Bool) {
        for signer in [Signer.confirm, .unlock] { SecItemDelete(query(tag(signer, macID, pending: pending)) as CFDictionary) }
    }

    static func has(_ signer: Signer, for macID: String) -> Bool { key(signer, macID: macID, context: nil) != nil }

    /// `X-SideA-Confirm` for `purpose` and `subject`, or nil when there's no key, the phone is locked (`unlock`),
    /// or Face ID was declined (`confirm`). Runs the Face ID prompt itself, so call it off the main thread's critical path.
    static func header(_ signer: Signer, macID: String, deviceID: String, purpose: ConfirmPurpose, subject: String,
                       reason: String = "Confirm on your Mac", fromNotification: Bool = false) async -> String? {
        guard fromNotification || !appLocked else {
            RemoteLog.log(.app, "no signature while the app is locked")
            return nil
        }
        return await Task.detached {
            let at = Int(Date.now.timeIntervalSince1970)
            let context = signer == .confirm ? faceID() : LAContext()
            context.localizedReason = reason
            guard let text = try? ConfirmMessage.text(macID: macID, deviceID: deviceID, purpose: purpose, subject: subject, at: at),
                  let key = key(signer, macID: macID, context: context) else { return nil }
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data(text.utf8) as CFData, &error) as Data? else {
                RemoteLog.log(.app, "\(signer == .confirm ? "Face ID" : "unlock") signature not made: \(error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0)")
                return nil
            }
            RemoteLog.log(.app, "\(signer == .confirm ? "Face ID" : "unlock") signed \(purpose.rawValue)")
            return ConfirmSignature(at: at, signer: signer, signature: signature).headerValue
        }.value
    }

    /// The app is behind its lock. A notification's answer comes from iOS's own unlock, in a process whose lock may
    /// never have been shown (a background launch), so only `fromNotification` signs then.
    static var appLocked: Bool {
        get { lock.withLock { locked } }
        set { lock.withLock { locked = newValue } }
    }

    nonisolated(unsafe) private static var locked = false

    /// One Face ID holds for 5 minutes (`OwnerAuth.grace`), so reopening the terminal a minute later doesn't ask again.
    /// The app lock's own Face ID holds for `unlockReuse` (`adopt`), so a destructive Allow just after it doesn't ask twice.
    nonisolated(unsafe) private static var shared: (context: LAContext, until: Date)?
    private static let lock = NSLock()
    static let unlockReuse: TimeInterval = 60
    /// As `OwnerAuth.grace`, which the extensions can't see.
    static let grace: TimeInterval = 5 * 60

    private static func faceID() -> LAContext {
        lock.withLock {
            if let shared, Date.now < shared.until { return shared.context }
            shared?.context.invalidate()
            let context = LAContext()
            context.touchIDAuthenticationAllowableReuseDuration = grace
            shared = (context, .now.addingTimeInterval(grace))
            return context
        }
    }

    /// The app lock's context, just evaluated. The confirm key still demands biometry (`.biometryCurrentSet`): an
    /// unlock by passcode satisfies nothing here, and the signature then asks for Face ID as before.
    static func adopt(_ context: LAContext) {
        lock.withLock {
            shared?.context.invalidate()
            shared = (context, .now.addingTimeInterval(unlockReuse))
        }
    }

    /// Ends the Face ID grace, as the app goes to the background.
    static func expire() { lock.withLock { shared?.context.invalidate(); shared = nil } }

    /// The terminal's signer, for `TerminalSession(confirm:)`.
    static func terminal(macID: String, deviceID: String) -> @Sendable (String) async -> String? {
        { name in
            await header(.confirm, macID: macID, deviceID: deviceID, purpose: .terminal, subject: ConfirmMessage.subject(terminal: name),
                         reason: "Open the terminal")
        }
    }

    // MARK: Keychain

    private static var group: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "SideAKeychainGroup") as? String, !group.hasPrefix(".") else { return nil }
        return group
    }

    private static func tag(_ signer: Signer, _ macID: String, pending: Bool = false) -> Data {
        Data("com.arnenoori.sidea.remote.\(signer == .confirm ? "confirm" : "unlock").\(macID)\(pending ? ".pending" : "")".utf8)
    }

    private static func query(_ tag: Data) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    private static func make(_ signer: Signer, macID: String) -> String? {
        let flags: SecAccessControlCreateFlags = signer == .confirm ? [.privateKeyUsage, .biometryCurrentSet] : [.privateKeyUsage]
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, nil) else { return nil }
        var privateAttributes: [String: Any] = [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: tag(signer, macID, pending: true),
                                                kSecAttrAccessControl as String: access]
        if let group { privateAttributes[kSecAttrAccessGroup as String] = group }
        var attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256,
                                         kSecPrivateKeyAttrs as String: privateAttributes]
        #if !targetEnvironment(simulator)
        attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        #endif
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error), let publicKey = SecKeyCopyPublicKey(key),
              let raw = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?, raw.count == 65 else {
            RemoteLog.error(.pairing, "\(signer == .confirm ? "Face ID" : "unlock") key not made: \(error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0)")
            return nil
        }
        return raw.base64URL
    }

    private static func key(_ signer: Signer, macID: String, context: LAContext?) -> SecKey? {
        var query: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag(signer, macID),
                                    kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecReturnRef as String: true]
        if let group { query[kSecAttrAccessGroup as String] = group }
        if let context { query[kSecUseAuthenticationContext as String] = context }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item else { return nil }
        return (item as! SecKey)
    }
}
