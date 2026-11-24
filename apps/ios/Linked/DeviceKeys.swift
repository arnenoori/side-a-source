import Foundation
import LocalAuthentication
import Security
import SideAProtocol
import SideARemoteShared

/// The phone's two Secure Enclave keys for one Mac. The Mac requires a signature from one of them for anything
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
            guard let text = try? ConfirmMessage.text(macID: macID, deviceID: deviceID, purpose: purpose, subject: subject, at: at) else { return nil }
            if signer == .unlock {
                guard let key = key(.unlock, macID: macID, context: LAContext()) else { return nil }
                switch sign(key, text) {
                case .success(let signature):
                    RemoteLog.log(.app, "unlock signed \(purpose.rawValue)")
                    return ConfirmSignature(at: at, signer: signer, signature: signature).headerValue
                case .failure(let code):
                    RemoteLog.log(.app, "unlock signature not made: \(code)")
                    return nil
                }
            }
            // A held context the key stops honouring costs one prompt, then a fresh one is evaluated. If even that is
            // refused, the key's own prompt signs and its context is kept: two prompts once, not one per message.
            for _ in 0..<2 {
                guard let grant = await hold.context(reason: reason, evaluate: { await evaluate(macID: macID, reason: $0) }),
                      let key = key(.confirm, macID: macID, context: grant.context) else { return nil }
                switch sign(key, text) {
                case .success(let signature):
                    RemoteLog.log(.app, "Face ID signed \(purpose.rawValue), \(grant.reused ? "held" : "fresh") context")
                    return ConfirmSignature(at: at, signer: signer, signature: signature).headerValue
                case .failure(let code):
                    RemoteLog.log(.app, "Face ID signature refused the \(grant.reused ? "held" : "fresh") context: \(code)")
                    hold.drop(grant.context, code: code)
                    if grant.reused { continue }
                    return signWithKeyPrompt(macID: macID, text: text, at: at, reason: reason)
                }
            }
            return nil
        }.value
    }

    /// The key asks for Face ID itself, and the context it asked with is kept for the next signature.
    private static func signWithKeyPrompt(macID: String, text: String, at: Int, reason: String) -> String? {
        let context = LAContext()
        context.localizedReason = reason
        guard let key = key(.confirm, macID: macID, context: context) else { return nil }
        switch sign(key, text) {
        case .success(let signature):
            hold.adopt(context)
            RemoteLog.log(.app, "Face ID signed through the key's own prompt")
            return ConfirmSignature(at: at, signer: .confirm, signature: signature).headerValue
        case .failure(let code):
            RemoteLog.log(.app, "Face ID signature not made through the key's own prompt: \(code)")
            return nil
        }
    }

    private enum Signed { case success(Data), failure(Int) }

    private static func sign(_ key: SecKey, _ text: String) -> Signed {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data(text.utf8) as CFData, &error) as Data? else {
            return .failure(error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0)
        }
        return .success(signature)
    }

    /// The app is behind its lock. A notification's answer comes from iOS's own unlock, in a process whose lock may
    /// never have been shown (a background launch), so only `fromNotification` signs then.
    static var appLocked: Bool {
        get { lock.withLock { locked } }
        set { lock.withLock { locked = newValue } }
    }

    nonisolated(unsafe) private static var locked = false
    private static let lock = NSLock()

    /// One Face ID holds for as long as the app is in use, so a permissive session asks once, not at every reply,
    /// however long its turns run. It ends (`expire`) when the app has been away as long as the app lock waits, and
    /// with the process. The app lock's own Face ID counts as that first one (`unlock`).
    ///
    /// What authorises a Secure Enclave key is its access control, evaluated with `LAContext.evaluateAccessControl`
    /// and `.useKeySign`. A context that merely passed `evaluatePolicy` is not documented to satisfy it.
    static let hold = FaceIDHold<LAContext>(invalidate: { $0.invalidate() }, log: { RemoteLog.log(.app, $0) })

    private static func evaluate(macID: String, reason: String) async -> FaceIDHold<LAContext>.Evaluated? {
        guard let access = accessControl(macID: macID) else { return nil }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        do {
            try await context.evaluateAccessControl(access, operation: .useKeySign, localizedReason: reason)
        } catch {
            RemoteLog.log(.app, "Face ID declined: \((error as NSError).code)")
            return nil
        }
        return .init(context: context)
    }

    /// The confirm key's own access control, so what is evaluated is what the key checks.
    private static func accessControl(macID: String) -> SecAccessControl? {
        if let key = key(.confirm, macID: macID, context: nil), let attributes = SecKeyCopyAttributes(key) as? [String: Any],
           let value = attributes[kSecAttrAccessControl as String], CFGetTypeID(value as CFTypeRef) == SecAccessControlGetTypeID() {
            // swiftlint:disable:next force_cast -- the type id is checked on the line above.
            return (value as! SecAccessControl)
        }
        return SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], nil)
    }

    /// The app lock's Face ID, taken as the confirm key's, so the first reply after unlocking doesn't ask again.
    /// `unpaired` (no key yet) leaves the lock to ask its own way.
    enum Unlock { case passed, declined, unpaired }

    static func unlock(macIDs: [String], reason: String) async -> Unlock {
        guard let macID = macIDs.first(where: { has(.confirm, for: $0) }),
              let access = accessControl(macID: macID) else { return .unpaired }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        do {
            try await context.evaluateAccessControl(access, operation: .useKeySign, localizedReason: reason)
        } catch {
            RemoteLog.log(.app, "app lock Face ID declined: \((error as NSError).code)")
            return .declined
        }
        hold.adopt(context)
        return .passed
    }

    static func expire(_ cause: String = "the app was away") { hold.expire(cause) }

    static func terminal(macID: String, deviceID: String) -> @Sendable (String) async -> String? {
        { name in
            await header(.confirm, macID: macID, deviceID: deviceID, purpose: .terminal, subject: ConfirmMessage.subject(terminal: name),
                         reason: "Open the terminal")
        }
    }

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
        // swiftlint:disable:next force_cast -- SecItemCopyMatching with kSecReturnRef returns a SecKey; a conditional cast to a CF type always succeeds and only warns.
        return (item as! SecKey)
    }
}
