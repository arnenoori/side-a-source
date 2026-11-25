import LocalAuthentication
import SideARemoteShared
import SwiftUI

enum Biometry: Equatable {
    case faceID, touchID, opticID, passcode

    static var current: Biometry { DeviceBiometry.shared.current }

    /// Asks LocalAuthentication. A biometry locked out for a while after failed tries is still the one the device has,
    /// so it keeps its name; one not enrolled, or none, is the passcode.
    static func read() -> Biometry {
        let context = LAContext()
        var error: NSError?
        let usable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        guard usable || error?.code == LAError.biometryLockout.rawValue else { return .passcode }
        return of(context.biometryType)
    }

    static func of(_ type: LABiometryType) -> Biometry {
        switch type {
        case .faceID: .faceID
        case .touchID: .touchID
        case .opticID: .opticID
        default: .passcode
        }
    }

    var name: String {
        switch self {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .passcode: "Passcode"
        }
    }

    var phrase: String { self == .passcode ? "your passcode" : name }

    var symbol: String {
        switch self {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .passcode: "lock"
        }
    }
}

@Observable
final class DeviceBiometry {
    nonisolated deinit {}

    static let shared = DeviceBiometry()
    private(set) var current = Biometry.read()

    func refresh() {
        let now = Biometry.read()
        if now != current { current = now }
    }
}

@Observable
final class AppLock {
    nonisolated deinit {}

    static let after: TimeInterval = 5 * 60
    static let key = "lock.enabled"

    private(set) var locked: Bool { didSet { DeviceKeys.appLocked = locked } }
    private var away = false
    @ObservationIgnored private var leftAt: Date?
    @ObservationIgnored private var asking = false
    /// Once per launch and per return from the background, not at every active: the Face ID sheet itself makes the app
    /// inactive and then active, and a declined prompt must not ask again at once.
    @ObservationIgnored private var warmDue = true

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if DEBUG
        if arguments.contains("--locked") { locked = true; DeviceKeys.appLocked = true; return }
        if arguments.contains("--demo") || arguments.contains("--no-lock") { locked = false; return }
        #endif
        locked = Self.enabled && !PairedMac.all().isEmpty
        DeviceKeys.appLocked = locked
    }

    var covered: Bool { locked || away }

    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    func phase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            away = true
            leftAt = .now
            warmDue = true
        case .active:
            if let leftAt, Date.now.timeIntervalSince(leftAt) >= Self.after {
                OwnerAuth.expire()
                if Self.enabled, !PairedMac.all().isEmpty { locked = true }
            }
            leftAt = nil
            away = false
            if locked {
                warmDue = false
                Task { await unlock() }
            } else if warmDue {
                warmDue = false
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--demo") { return }
                #endif
                Task { await DeviceKeys.prewarm(macIDs: PairedMac.all().map(\.endpoint.macID)) }
            }
        default:
            away = true
        }
    }

    func unlock() async {
        guard locked, !asking else { return }
        asking = true
        defer { asking = false }
        let keyed = await DeviceKeys.unlock(macIDs: PairedMac.all().map(\.endpoint.macID), reason: "Unlock Side A Remote")
        if keyed == .passed {
            locked = false
            return
        }
        if keyed == .unpaired {
            let biometric = LAContext()
            biometric.localizedFallbackTitle = ""
            if (try? await biometric.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock Side A Remote")) == true {
                locked = false
                return
            }
        }
        do {
            if try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Side A Remote") { locked = false }
        } catch let error as LAError where error.code == .passcodeNotSet {
            // The passcode was removed after the lock was turned on: nothing can ask, and nothing is protected.
            locked = false
        } catch {}
    }
}

@MainActor
final class LockWindow {
    nonisolated deinit {}

    static let shared = LockWindow()
    static let level = UIWindow.Level.alert + 1
    private(set) var window: UIWindow?

    func update(_ lock: AppLock) {
        guard lock.covered else {
            window?.isHidden = true
            window = nil
            return
        }
        if lock.locked { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState != .background }) ?? scenes.first else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = Self.level
        let host = UIHostingController(rootView: LockScreen(lock: lock).tint(Accent.current.color).preferredColorScheme(Theme.current.scheme).dynamicTypeSize(...DynamicTypeSize.xxLarge))
        host.view.accessibilityViewIsModal = true
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }
}

struct LockScreen: View {
    let lock: AppLock

    var body: some View {
        VStack(spacing: Space.l) {
            AppIconArt(side: 88)
            Button("Unlock") { Task { await lock.unlock() } }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .opacity(lock.locked ? 1 : 0)
                .accessibilityHidden(!lock.locked)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
