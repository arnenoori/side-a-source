import AppKit
import CoreGraphics
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import ServiceManagement
import SideACore
import SideAKeepAwakeCore

enum HelperStatus: Equatable {
    case off, needsApproval, ready, unavailable
}

@MainActor
protocol SleepSystem: AnyObject {
    func workingAgents() -> Int
    func power() -> KeepAwake.Power
    func hold(_ reason: String) -> Bool
    func release()
    var helper: HelperStatus { get }
    func registerHelper() -> HelperStatus
    func unregisterHelper() async
    func openLoginItems()
    /// Replies whether sleep is disabled afterwards, or nil when the helper can't be reached.
    func requestLidSleep(_ disabled: Bool, completion: @escaping @MainActor @Sendable (Bool?) -> Void)
    func restoreBeforeQuit()
    func lidClosed() -> Bool
    func externalDisplay() -> Bool
    func sleepNow()
}

@MainActor @Observable
final class KeepAwakeController {
    static let enabledKey = "keepAwake"
    static let lidClosedKey = "keepAwakeLidClosed"
    static let onBatteryKey = "keepAwakeOnBattery"
    static let interval: Duration = .seconds(30)

    private(set) var settings: KeepAwake.Settings
    private(set) var state = KeepAwake()
    private(set) var holding = false
    private(set) var sleepDisabled = false
    private(set) var offersLid: Bool
    private(set) var helper: HelperStatus = .off
    private(set) var busy = false
    /// Sleep came back on with the lid closed, so the idle assertion stays released until the lid opens.
    private(set) var lidSleepPending = false
    var error: String?
    @ObservationIgnored private let system: SleepSystem?
    /// Whether the Mac runs on its adapter (a desktop always does); nil in the demo.
    var onPower: Bool? { system?.power().onAC }
    /// The adapter and the battery's charge; nil in the demo.
    var power: KeepAwake.Power? { system?.power() }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lidCheck: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var asked = false
    @ObservationIgnored private var handingOff = false

    init(system: SleepSystem?, defaults: UserDefaults = .standard) {
        self.system = system
        self.defaults = defaults
        settings = KeepAwake.Settings(enabled: defaults.bool(forKey: Self.enabledKey),
                                      lidClosed: defaults.bool(forKey: Self.lidClosedKey),
                                      onBattery: defaults.bool(forKey: Self.onBatteryKey))
        offersLid = system == nil
    }

    /// The demo shares the real app's defaults, so its toggles stay on screen only.
    private func save(_ value: Bool, _ key: String) {
        if system != nil { defaults.set(value, forKey: key) }
    }

    func start() {
        guard let system else { return }
        // An unsigned build's helper accepts no caller, so the lid option couldn't work there.
        offersLid = system.power().battery != nil && KeepAwakeHelper.teamID() != nil
        helper = system.helper
        observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        restartLoop()
    }

    /// Releases everything synchronously; macOS ends the process right after willTerminate.
    func stop() {
        loop?.cancel(); loop = nil
        cancelLidCheck()
        guard let system else { return }
        if holding { system.release(); holding = false }
        // An update's relaunch asks again within the helper's handover; anything else gives sleep back now.
        if asked, !handingOff { system.restoreBeforeQuit() }
        asked = false
    }

    func handOff() { handingOff = true }

    func check(now: Double = Date().timeIntervalSince1970) {
        guard let system else { return }
        state.observe(working: settings.enabled ? system.workingAgents() : 0, now: now)
        if lidSleepPending, !system.lidClosed() { cancelLidCheck() }
        if settings.lidClosed { helper = system.helper }
        let power = settings.lidClosed ? system.power() : KeepAwake.Power(onAC: false, battery: nil)
        if state.disablesSleep(settings, power: power, now: now), helper == .ready {
            cancelLidCheck()
            asked = true
            system.requestLidSleep(true) { [weak self] disabled in
                guard let self else { return }
                sleepDisabled = disabled == true
                error = disabled == true ? nil : "Side A's helper couldn't keep the Mac awake with the lid closed. Turn the option off and on again."
            }
        } else if asked {
            restoreSleep()
        }
        if state.holdsAssertion(settings, now: now), !lidSleepPending {
            holding = system.hold(state.reason)
        } else if holding {
            system.release(); holding = false
        }
    }

    var line: String? { state.line(settings, sleepDisabled: sleepDisabled, now: Date().timeIntervalSince1970) }
    var accessibilityLine: String? { state.accessibilityLine(settings, sleepDisabled: sleepDisabled, now: Date().timeIntervalSince1970) }

    func setEnabled(_ value: Bool) {
        settings.enabled = value
        save(value, Self.enabledKey)
        restartLoop()
    }

    func setLidClosed(_ value: Bool) async {
        guard let system else {
            error = "The demo doesn't change power settings."
            return
        }
        error = nil
        if value {
            helper = system.registerHelper()
            switch helper {
            case .unavailable:
                error = "Only Side A in Applications can keep a closed Mac awake."
                return
            case .off:
                error = "macOS didn't add Side A's helper. Try again, or check Login Items in System Settings."
                return
            case .needsApproval, .ready:
                break
            }
        } else {
            settings.lidClosed = false
            if asked { restoreSleep() }
            busy = true
            await system.unregisterHelper()
            busy = false
            helper = system.helper
        }
        settings.lidClosed = value
        save(value, Self.lidClosedKey)
        check()
    }

    func setOnBattery(_ value: Bool) {
        settings.onBattery = value
        save(value, Self.onBatteryKey)
        check()
    }

    func refreshHelper() {
        guard let system else { return }
        let status = system.helper
        guard status != helper else { return }
        helper = status
        check()
    }

    func openLoginItems() { system?.openLoginItems() }

    func uninstall() async {
        stop()
        guard let system, system.helper != .off else { return }
        await system.unregisterHelper()
        helper = system.helper
    }

    private func restoreSleep(checkLid: Bool = true) {
        guard let system else { return }
        asked = false
        let wasDisabled = sleepDisabled
        system.requestLidSleep(false) { [weak self] disabled in
            guard let self else { return }
            sleepDisabled = disabled == true
            if wasDisabled, disabled == false, checkLid, system.lidClosed(), !system.externalDisplay() { closedLidRestored() }
        }
    }

    private func closedLidRestored() {
        lidSleepPending = true
        if holding { system?.release(); holding = false }
        lidCheck?.cancel()
        lidCheck = Task { [weak self] in
            let wall = ContinuousClock.now, awake = SuspendingClock.now
            try? await Task.sleep(for: .seconds(ClosedLid.settle))
            guard !Task.isCancelled else { return }
            self?.closedLidCheck(elapsed: Self.seconds(ContinuousClock.now - wall), awake: Self.seconds(SuspendingClock.now - awake))
        }
    }

    func closedLidCheck(elapsed: TimeInterval, awake: TimeInterval) {
        guard lidSleepPending, let system else { return }
        if system.externalDisplay() { cancelLidCheck(); return }
        if ClosedLid.sleepNow(lidClosed: system.lidClosed(), externalDisplay: false, elapsed: elapsed, awake: awake) { system.sleepNow() }
    }

    private func cancelLidCheck() {
        lidSleepPending = false
        lidCheck?.cancel(); lidCheck = nil
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func restartLoop() {
        loop?.cancel(); loop = nil
        guard system != nil else { return }
        check()
        guard settings.enabled else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled, let self else { return }
                self.check()
            }
        }
    }
}

extension HelperStatus {
    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .ready
        case .requiresApproval: self = .needsApproval
        case .notFound: self = .unavailable
        default: self = .off
        }
    }
}

@MainActor
final class MacSleepSystem: SleepSystem {
    private let root: String
    private let service = SMAppService.daemon(plistName: KeepAwakeHelper.plistName)
    private var connection: NSXPCConnection?
    private var assertion: IOPMAssertionID = 0
    private var reason: String?

    init(root: String) { self.root = root }

    func workingAgents() -> Int {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let now = Date()
        return AgentActivity.claudeWorking(registry: home.appendingPathComponent(".claude/sessions"),
                                           projects: home.appendingPathComponent(".claude/projects"), excluding: root, now: now)
            + AgentActivity.codexWorking(sessions: home.appendingPathComponent(".codex/sessions"), now: now)
    }

    func power() -> KeepAwake.Power {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return KeepAwake.Power(onAC: true, battery: nil) }
        let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var battery: Int?
        for item in (IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as [CFTypeRef]?) ?? [] {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int, let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            battery = current * 100 / max
        }
        return KeepAwake.Power(onAC: source != kIOPMBatteryPowerKey, battery: battery)
    }

    func hold(_ reason: String) -> Bool {
        if assertion != 0 {
            if reason != self.reason {
                IOPMAssertionSetProperty(assertion, kIOPMAssertionNameKey as CFString, reason as CFString)
                self.reason = reason
            }
            return true
        }
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                          IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) == kIOReturnSuccess else { return false }
        assertion = id
        self.reason = reason
        return true
    }

    func release() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
        reason = nil
    }

    var helper: HelperStatus { HelperStatus(service.status) }

    func registerHelper() -> HelperStatus {
        try? service.register()
        return helper
    }

    func unregisterHelper() async {
        connection?.invalidate()
        connection = nil
        try? await service.unregister()
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    func requestLidSleep(_ disabled: Bool, completion: @escaping @MainActor @Sendable (Bool?) -> Void) {
        guard let opened = connect() else { return completion(nil) }
        // A request after this one must not ride a connection that closes when this reply lands.
        if !disabled { connection = nil }
        nonisolated(unsafe) let connection = opened
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            Task { @MainActor in completion(nil) }
        } as? KeepAwakeHelping
        proxy?.setLidSleepDisabled(disabled) { result in
            // Nothing left to hold open once sleep is given back; closing lets the helper exit.
            if !disabled { connection.invalidate() }
            Task { @MainActor in completion(result) }
        }
    }

    func restoreBeforeQuit() {
        guard let connection else { return }
        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { _ in } as? KeepAwakeHelping
        proxy?.setLidSleepDisabled(false) { _ in }
        connection.invalidate()
    }

    private func connect() -> NSXPCConnection? {
        if let connection { return connection }
        guard let requirement = KeepAwakeHelper.helperRequirement(team: KeepAwakeHelper.teamID()) else { return nil }
        let connection = NSXPCConnection(machServiceName: KeepAwakeHelper.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: KeepAwakeHelping.self)
        connection.setCodeSigningRequirement(requirement)
        connection.invalidationHandler = { [weak self, weak connection] in
            Task { @MainActor in if self?.connection === connection { self?.connection = nil } }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    func lidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
    }

    func externalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    func sleepNow() {
        Task { _ = await ProcessRunner.run(KeepAwakeHelper.pmset, ["sleepnow"], timeout: nil) }
    }
}
