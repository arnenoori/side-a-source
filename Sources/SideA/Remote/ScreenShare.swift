import AppKit
import ApplicationServices
import CoreGraphics
import Observation
import SideAProtocol

/// Screen on iPhone: the two switches, both off until turned on at the Mac, the permissions they need, and who is
/// watching now. Permissions are only ever asked for from here, on the owner's click, never from a phone's request.
@MainActor @Observable
final class ScreenShare {
    nonisolated static let enabledKey = "remoteScreen"
    nonisolated static let controlKey = "remoteScreenControl"
    // swiftlint:disable:next user_defaults_standard -- ScreenShare owns the two screen switches; nothing else reads them
    nonisolated static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    // swiftlint:disable:next user_defaults_standard -- ScreenShare owns the two screen switches; nothing else reads them
    nonisolated static var controlEnabled: Bool { UserDefaults.standard.bool(forKey: controlKey) }

    static let recordingSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let accessibilitySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    struct Watcher: Equatable {
        let device: String
        let name: String
        let mode: ScreenMode
        let route: ScreenRoute
        let since: Date
    }

    private(set) var on = ScreenShare.enabled
    private(set) var control = ScreenShare.controlEnabled
    private(set) var recording = CGPreflightScreenCaptureAccess()
    private(set) var accessibility = AXIsProcessTrusted()
    private(set) var watcher: Watcher?
    @ObservationIgnored weak var hub: ScreenHub?
    @ObservationIgnored var deviceName: (String) -> String? = { _ in nil }

    func setOn(_ value: Bool) {
        on = value
        // swiftlint:disable:next user_defaults_standard -- ScreenShare owns the two screen switches; nothing else reads them
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
        RemoteLog.shared("screen sharing turned \(value ? "on" : "off")")
        if value, ScreenStandIn.current == nil, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !value { end(.off) }
        refresh()
    }

    func setControl(_ value: Bool) {
        control = value
        // swiftlint:disable:next user_defaults_standard -- ScreenShare owns the two screen switches; nothing else reads them
        UserDefaults.standard.set(value, forKey: Self.controlKey)
        RemoteLog.shared("screen control turned \(value ? "on" : "off")")
        if value, ScreenStandIn.current == nil, !AXIsProcessTrusted() { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
        hub.map { hub in hub.queue.async { hub.controlChanged() } }
        refresh()
    }

    func refresh() {
        recording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    func end(_ reason: ScreenRefusal = .ended) {
        hub.map { hub in hub.queue.async { hub.end(reason) } }
    }

    /// `order` is the hub's count: a report older than one already applied came late and is dropped.
    @ObservationIgnored private var applied = 0

    func began(device: String, mode: ScreenMode, route: ScreenRoute, order: Int) {
        guard order > applied else { return }
        applied = order
        watcher = Watcher(device: device, name: deviceName(device) ?? "An iPhone", mode: mode, route: route, since: Date())
    }

    func ended(device: String, order: Int) {
        guard order > applied else { return }
        applied = order
        if watcher?.device == device { watcher = nil }
    }
}
