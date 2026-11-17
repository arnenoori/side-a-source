import LocalAuthentication
import SideARemoteShared
import SwiftUI

/// What this device unlocks with, for copy that names it: an iPad may have Touch ID, and a device with none enrolled
/// falls back to its passcode.
enum Biometry: Equatable {
    case faceID, touchID, opticID, passcode

    /// As of the app's last activation (`DeviceBiometry`), so a view body never waits on LocalAuthentication.
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

    /// "Face ID", or "Passcode" for a title.
    var name: String {
        switch self {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .passcode: "Passcode"
        }
    }

    /// "Face ID", or "your passcode" inside a sentence.
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

/// The device's biometry, read once at launch and again each time the app becomes active (Settings can enroll or
/// remove it meanwhile), and watched by the views that name it.
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

/// Face ID or the passcode on opening Side A Remote, and on coming back after `after` away (on by default,
/// Settings › Security). A phone left unlocked shouldn't hand over sessions, the terminal and Allow.
@Observable
final class AppLock {
    nonisolated deinit {}

    static let after: TimeInterval = 5 * 60
    static let key = "lock.enabled"

    private(set) var locked: Bool { didSet { DeviceKeys.appLocked = locked } }
    /// Not the active app: the switcher's snapshot and anyone glancing see the cover, not a transcript.
    private var away = false
    @ObservationIgnored private var leftAt: Date?
    @ObservationIgnored private var asking = false

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if DEBUG
        // Screenshots and the demo run unlocked.
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
            OwnerAuth.expire()
        case .active:
            if let leftAt, Date.now.timeIntervalSince(leftAt) >= Self.after, Self.enabled, !PairedMac.all().isEmpty { locked = true }
            leftAt = nil
            away = false
            if locked { Task { await unlock() } }
        default:
            away = true
        }
    }

    func unlock() async {
        guard locked, !asking else { return }
        asking = true
        defer { asking = false }
        // Face ID first, so replies and allows after it sign without asking again; the passcode only when that's refused.
        let biometric = LAContext()
        biometric.localizedFallbackTitle = ""
        if (try? await biometric.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock Side A Remote")) == true {
            DeviceKeys.adopt(biometric)
            locked = false
            return
        }
        do {
            if try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Side A Remote") { locked = false }
        } catch let error as LAError where error.code == .passcodeNotSet {
            // The passcode was removed after the lock was turned on: nothing can ask, and nothing is protected.
            locked = false
        } catch {}
    }
}

/// The lock and the cover in their own window, above every sheet, cover and alert the app has up, so a request or
/// terminal that was open when the app locked (or that a notification tap opens while it's locked) stays out of reach.
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
        let host = UIHostingController(rootView: LockScreen(lock: lock).tint(Accent.current.color).dynamicTypeSize(...DynamicTypeSize.xxLarge))
        host.view.accessibilityViewIsModal = true
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }
}

/// What shows while locked: the icon on the system background, and Unlock if Face ID was dismissed. Away from the
/// app, the icon alone.
struct LockScreen: View {
    let lock: AppLock

    var body: some View {
        VStack(spacing: Space.l) {
            Image("AppIconImage")
                .resizable()
                .frame(width: 88, height: 88)
                .clipShape(.rect(cornerRadius: 20, style: .continuous))
                .accessibilityHidden(true)
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
