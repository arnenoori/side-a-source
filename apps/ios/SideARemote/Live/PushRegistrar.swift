import ActivityKit
import CryptoKit
import Foundation
import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import UIKit
import UserNotifications

/// This iPhone's APNs token on its way to the Mac (M2.1): `POST /v1/devices/push` on every connection
/// and whenever the token or the notification settings change. The Mac registers it with the relay,
/// which sends one silent push to prove the token is ours; `RelayDevice` answers it. A new token also goes
/// straight to the relay, so pushes follow it while the Mac is out of reach.
@MainActor
final class PushRegistrar {
    static let shared = PushRegistrar()

    private let defaults = UserDefaults(suiteName: SharedStorage.appGroup) ?? .standard
    private static let tokenKey = "push.apnsToken"
    /// A new token some relay hasn't heard of yet, for want of a connection.
    private static let relayOwedKey = "push.relayOwed"

    /// Hex, as APNs gave it; nil until notifications are allowed and iOS hands one over.
    var apnsToken: String? { defaults.string(forKey: Self.tokenKey) }

    /// Called whenever a token changes, one per paired Mac by its id; each link reports it to its own Mac,
    /// which registers it with its own relay install.
    var observers: [String: () -> Void] = [:]

    private func onChange() { for observer in observers.values { observer() } }

    /// ActivityKit's token for starting this app's Live Activity by push (iOS 17.2+).
    private(set) var pushToStartToken: String?
    /// Each running activity's update token, by activity id: the Mac learns activity ids only from these.
    private(set) var activityTokens: [String: String] = [:]
    /// Each running activity's `MacActivityAttributes.macID`, the only thing that says whose it is.
    private var activityMacs: [String: String] = [:]
    private var watching = false

    /// At launch: once notifications are allowed, iOS needs asking every launch to hand back the token.
    func registerIfAllowed() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        RemoteLog.log(.push, "notifications \(status.rawValue)")
        guard [.authorized, .provisional, .ephemeral].contains(status) else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func received(_ token: Data) {
        let hex = Self.hex(token)
        if hex != apnsToken {
            defaults.set(hex, forKey: Self.tokenKey)
            defaults.set(true, forKey: Self.relayOwedKey)
            onChange()
        }
        guard defaults.bool(forKey: Self.relayOwedKey) else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? PushRegistration.defaultBundleID
        Task {
            if await RelayDevice.report(token: hex, bundleID: bundleID, environment: Self.environment) {
                defaults.set(false, forKey: Self.relayOwedKey)
            }
            await reportActivities()
        }
    }

    /// What the Mac hands the relay: the token, which app it belongs to (the `apns-topic`), which APNs
    /// host (fixed by the build configuration), and what the user wants to hear about.
    var registration: PushRegistration? {
        guard let apnsToken else { return nil }
        return PushRegistration(apnsToken: apnsToken, bundleID: Bundle.main.bundleIdentifier ?? PushRegistration.defaultBundleID,
                                apnsEnvironment: Self.environment, pushToStartToken: pushToStartToken,
                                activityTokens: activityTokens, prefs: .stored)
    }

    /// `SideAAPNsEnvironment` from the xcconfigs: sandbox in Debug, production in Release.
    static var environment: PushRegistration.Environment {
        (Bundle.main.object(forInfoDictionaryKey: "SideAAPNsEnvironment") as? String).map(PushRegistration.Environment.init) ?? .production
    }

    /// Once per launch: the push-to-start token, then every activity's tokens as it starts (by push,
    /// with the app launched in the background) and until it ends or is swiped away.
    func watchActivities() {
        guard !watching else { return }
        watching = true
        Task {
            for await token in Activity<MacActivityAttributes>.pushToStartTokenUpdates {
                let hex = Self.hex(token)
                guard hex != pushToStartToken else { continue }
                pushToStartToken = hex
                onChange()
            }
        }
        endActivitiesIfOff()
        for activity in Activity<MacActivityAttributes>.activities { watch(activity) }
        Task {
            for await activity in Activity<MacActivityAttributes>.activityUpdates { watch(activity) }
        }
    }

    private func watch(_ activity: Activity<MacActivityAttributes>) {
        let macID = activity.attributes.macID
        if Self.endsWhenOff(macID: macID, enabled: NotificationPrefs.stored.liveActivity) { return endActivitiesIfOff() }
        activityMacs[activity.id] = macID
        Task {
            for await token in activity.pushTokenUpdates {
                let hex = Self.hex(token)
                guard activityTokens[activity.id] != hex else { continue }
                activityTokens[activity.id] = hex
                onChange()
                await RelayDevice.putActivity(activity.id, token: hex, macID: macID, bundleID: Self.bundleID, environment: Self.environment)
            }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                // Swiped away or over: the Mac stops updating it and won't start another until it next goes busy.
                activityMacs[activity.id] = nil
                await RelayDevice.deleteActivity(activity.id, macID: macID)
                if activityTokens.removeValue(forKey: activity.id) != nil { onChange() }
            }
        }
    }

    /// Live Activity off in Settings: nothing updates a card any more, so none stays up with Allow and Deny frozen on it.
    func endActivitiesIfOff() {
        let enabled = NotificationPrefs.stored.liveActivity
        Task {
            for activity in Activity<MacActivityAttributes>.activities where Self.endsWhenOff(macID: activity.attributes.macID, enabled: enabled) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        onChange()
    }

    /// The demo's activity is its own, and goes with the demo.
    static func endsWhenOff(macID: String, enabled: Bool) -> Bool { !enabled && macID != NotificationAnswer.demoMac }

    /// Every running activity's update token to its Mac's relay, which is what the relay's updates and ends look up. The
    /// relay drops them with a new device token and refuses them until the device is proven, so this runs after both.
    func reportActivities() async {
        for (id, token) in activityTokens {
            guard let macID = activityMacs[id] else { continue }
            await RelayDevice.putActivity(id, token: token, macID: macID, bundleID: Self.bundleID, environment: Self.environment)
        }
    }

    private static var bundleID: String { Bundle.main.bundleIdentifier ?? PushRegistration.defaultBundleID }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    func report(to client: RemoteClient) async {
        guard let registration else {
            RemoteLog.log(.push, "registration skipped: no APNs token")
            return
        }
        do {
            try await client.registerPush(registration)
            RemoteLog.log(.push, "registered with \(client.endpoint.name): \(registration.activityTokens.count) activities, push-to-start \(registration.pushToStartToken == nil ? "no" : "yes")")
            await reportActivities()
        } catch {
            RemoteLog.error(.push, "registration failed: \(KitLog.describe(error))")
        }
    }
}

extension NotificationPrefs {
    /// The Notifications and Live Activity toggles in Settings, by their storage keys.
    static var stored: NotificationPrefs {
        let defaults = UserDefaults.standard
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        return NotificationPrefs(requests: flag("notify.requests", true), questions: flag("notify.questions", true),
                                 plans: flag("notify.plans", true), finished: flag("notify.finished", true),
                                 limits: flag("notify.limits", false), timeSensitiveRequests: flag("notify.timeSensitive", true),
                                 liveActivity: flag("activity.enabled", true), suppressWhileWatching: flag("notify.quietWhileWatching", true),
                                 health: flag("notify.health", true), rotation: flag("notify.rotation", false))
    }
}

/// The phone's own narrow way to the relay, with its `d1.<install>.<device>.<secret>` bearer: answering the
/// token check, and token refreshes while the Mac is out of reach.
enum RelayDevice {
    /// The relay's silent check, `{"verify": {"install", "device", "challenge"}}`: true when it was ours and answered.
    static func answer(_ userInfo: [AnyHashable: Any]) async -> Bool {
        guard let verify = userInfo["verify"] as? [String: Any], let install = verify["install"] as? String,
              let device = verify["device"] as? String, let challenge = verify["challenge"] as? String,
              let mac = PairedMac.all().first(where: { $0.relayInstallID == install && $0.deviceID == device }),
              var request = request("POST", "device/verify", mac: mac) else { return false }
        request.httpBody = try? JSONEncoder().encode(["challenge": challenge])
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            RemoteLog.error(.push, "relay verify failed to send")
            return false
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        RemoteLog.log(.push, "relay verify → \(status)")
        return (200..<300).contains(status)
    }

    typealias Send = @Sendable (URLRequest) async throws -> Int

    static let deliver: Send = { request in
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// `PUT /v1/device/tokens` to each paired Mac's relay. False when one couldn't be reached, so it's owed for next launch;
    /// a relay that answers has had its say, even if that's a refusal the Mac's own registration will settle.
    static func report(token: String, bundleID: String, environment: PushRegistration.Environment, macs: [PairedMac] = PairedMac.all(),
                       send: Send = deliver) async -> Bool {
        var reached = true
        for mac in macs {
            guard var request = request("PUT", "device/tokens", mac: mac) else { continue }
            request.httpBody = try? JSONEncoder().encode(["apnsToken": token, "bundleID": bundleID, "apnsEnvironment": environment.rawValue])
            do {
                let status = try await send(request)
                RemoteLog.log(.push, "relay tokens for \(mac.endpoint.name) → \(status)")
            } catch {
                RemoteLog.error(.push, "relay tokens for \(mac.endpoint.name) failed: \(KitLog.describe(error))")
                reached = false
            }
        }
        return reached
    }

    /// What a Live Activity's attributes call the Mac, which the relay derives from its install: no paired id says it.
    static func activityMacID(install: String) -> String {
        Data(SHA256.hash(data: Data("SideA macID v1\n\(install)".utf8)).prefix(12)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func mac(activity macID: String, in macs: [PairedMac]) -> PairedMac? {
        macs.first { $0.relayInstallID.map(activityMacID(install:)) == macID }
    }

    /// `PUT /v1/device/activities/{id}`: the update token, without which the relay answers `gone` to every update and end.
    /// Best effort: the next connection or token change sends it again.
    static func putActivity(_ id: String, token: String, macID: String, bundleID: String, environment: PushRegistration.Environment,
                            macs: [PairedMac] = PairedMac.all(), send: Send = deliver) async {
        guard let mac = mac(activity: macID, in: macs), var request = request("PUT", "device/activities/\(id)", mac: mac) else { return }
        request.httpBody = try? JSONEncoder().encode(["updateToken": token, "bundleID": bundleID, "apnsEnvironment": environment.rawValue])
        await activityCall(request, doing: "activity token", mac: mac, send: send)
    }

    /// `DELETE /v1/device/activities/{id}`: it ended or was swiped away.
    static func deleteActivity(_ id: String, macID: String, macs: [PairedMac] = PairedMac.all(), send: Send = deliver) async {
        guard let mac = mac(activity: macID, in: macs), let request = request("DELETE", "device/activities/\(id)", mac: mac) else { return }
        await activityCall(request, doing: "activity end", mac: mac, send: send)
    }

    private static func activityCall(_ request: URLRequest, doing: String, mac: PairedMac, send: Send) async {
        do {
            RemoteLog.log(.push, "relay \(doing) for \(mac.endpoint.name) → \(try await send(request))")
        } catch {
            RemoteLog.error(.push, "relay \(doing) for \(mac.endpoint.name) failed: \(KitLog.describe(error))")
        }
    }

    private static func request(_ method: String, _ path: String, mac: PairedMac) -> URLRequest? {
        guard let install = mac.relayInstallID, let relay = mac.relayURL, let secret = SharedKeychain.shared.data("secret.\(mac.endpoint.macID)"),
              let url = URL(string: "\(relay)/v1/\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoded = secret.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        request.setValue("Bearer d1.\(install).\(mac.deviceID).\(encoded)", forHTTPHeaderField: "Authorization")
        return request
    }
}
