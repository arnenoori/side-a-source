import Foundation
import Network
import Observation
import os
import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import UIKit

/// One pairing attempt from a scanned code or a pairing link (setup, "Pairing"): reach the Mac, check
/// its key, show the comparison code while the user clicks Pair on the Mac, then keep the token.
@Observable
final class PairingRun {
    enum Step: Int, CaseIterable {
        case reaching, key, code, done
    }

    enum Phase: Equatable {
        case running(Step)
        /// "482 913", until the Mac answers or the deadline passes.
        case comparing(code: String, deadline: Date)
        case paired(PairedMac)
        case failed(PairingFailure)
    }

    let invitation: PairingClient.Invitation
    private(set) var phase: Phase = .running(.reaching)
    /// The name the Mac gives in its hello, for a code that carries none.
    private(set) var reportedName: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The code posted and waiting for Pair on the Mac, so Cancel can void it there too.
    @ObservationIgnored private var pending: (client: PairingClient, attempt: PairingClient.Attempt)?
    /// Paired on the Mac but not yet kept here, when the keychain refused it; Try Again saves it again.
    @ObservationIgnored private var unsaved: PairingClient.Paired?

    init(invitation: PairingClient.Invitation) { self.invitation = invitation }

    /// A code without a name shows the address, which reads at the start of a sentence too.
    var macName: String {
        invitation.macName ?? reportedName ?? invitation.address.split(separator: ":").first.map(String.init) ?? invitation.address
    }

    /// What the Mac will call this iPhone. Without the user-assigned device name entitlement iOS
    /// says "iPhone", and the Mac adds the model.
    static var deviceName: String { UIDevice.current.name }

    func start(replacing old: PairedMac? = nil) {
        task?.cancel()
        if let unsaved {
            phase = .running(.done)
            task = Task { keep(unsaved) }
            return
        }
        phase = .running(.reaching)
        task = Task { await run(replacing: old) }
    }

    /// Stops here and voids the attempt on the Mac, so its Pair button can't pair a phone that left.
    func cancel() {
        task?.cancel()
        if let (client, attempt) = pending {
            pending = nil
            Task { await client.cancel(attempt: attempt) }
        }
    }

    #if DEBUG
    /// A run held at one phase, for previews and screenshots.
    static func sample(_ phase: Phase) -> PairingRun {
        let run = PairingRun(invitation: PairingClient.Invitation(address: "100.101.12.4:47800", fp: String(repeating: "A", count: 43), macName: "MacBook Pro", macID: "sample", code: "ABCD2345"))
        run.phase = phase
        return run
    }
    #endif

    private func run(replacing old: PairedMac?) async {
        let info = ClientInfo.current
        let device = DeviceInfo(name: Self.deviceName, model: Self.model, system: "iOS \(UIDevice.current.systemVersion)",
                                app: info.version, build: info.build, capabilities: info.capabilities)
        // Two Secure Enclave keys for this Mac, so it can ask for Face ID or an unlocked phone behind the token.
        let keys = invitation.macID.flatMap(DeviceKeys.create(for:))
        if keys == nil { RemoteLog.error(.pairing, "pairing without device keys") }
        let client = PairingClient(invitation: invitation, device: device, replaces: old?.deviceID,
                                   confirmKey: keys?.confirm, unlockKey: keys?.unlock)
        RemoteLog.log(.pairing, "start \(invitation.addresses.joined(separator: ", "))"
                      + " replacing \(old == nil ? "none" : "a pairing")")
        do {
            // Reaching the Mac and settling its key spend nothing; check versions before the code is posted.
            let probe = try await client.probe(info: info)
            // An unauthenticated hello may leave the name out; then the address stands in until paired.
            reportedName = probe.hello.mac.name.isEmpty ? nil : probe.hello.mac.name
            if let failure = PairingFailure(probe.hello, macName: macName, clientBuild: info.build) {
                phase = .failed(failure)
                return
            }
            phase = .running(.code)
            let attempt = try await client.start(probe)
            pending = (client, attempt)
            phase = .comparing(code: PairingTranscript.display(attempt.comparisonCode),
                               deadline: Date(timeIntervalSince1970: min(attempt.pending.expiresAt, Date.now.timeIntervalSince1970 + 60)))
            let paired = try await client.wait(attempt)
            pending = nil
            keep(paired)
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
        } catch {
            // The Mac voids a code whose comparison ran out, so retrying it can only fail.
            let spent = pending != nil
            pending = nil
            RemoteLog.error(.pairing, "failed: \(KitLog.describe(error))")
            var failure = await PairingFailure(error, macName: macName, codeSpent: spent)
            // What each address did, under whatever Details already says.
            let tried = client.probeLog.lines
            if !tried.isEmpty {
                failure.detail = ([failure.detail].compactMap { $0 } + tried).joined(separator: "\n")
            }
            phase = .failed(failure)
        }
    }

    /// Paired is only announced once every credential is in the keychain.
    private func keep(_ paired: PairingClient.Paired) {
        do {
            let saved = try PairedMac.save(paired, deviceName: Self.deviceName, tailnet: invitation.tailnet)
            if let macID = invitation.macID { DeviceKeys.promote(for: macID) }
            phase = .paired(saved)
            unsaved = nil
            RemoteLog.log(.pairing, "paired with \(paired.endpoint.name), push key \(paired.pushKey == nil ? "no" : "yes")")
        } catch {
            RemoteLog.error(.pairing, "keychain refused the pairing")
            unsaved = paired
            phase = .failed(PairingFailure(title: "Couldn't save the pairing on this iPhone.", primary: .tryAgain))
        }
    }

    /// "iPhone18,1".
    private static var model: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// A failure card's words and its one primary action (setup, "Failure cards").
struct PairingFailure: Equatable {
    enum Action: Equatable {
        case tryAgain, scanAgain, scanNewCode, openTailscale, openSettings, appStore
    }

    var title: String
    /// What went wrong underneath, behind Details; never the headline.
    var detail: String?
    var primary: Action
    var secondary: Action?
    /// 429: Try Again waits this long.
    var retryAfter: Double?

    init(title: String, detail: String? = nil, primary: Action, secondary: Action? = nil, retryAfter: Double? = nil) {
        self.title = title; self.detail = detail; self.primary = primary; self.secondary = secondary; self.retryAfter = retryAfter
    }

    init(_ error: any Error, macName mac: String, codeSpent: Bool = false) async {
        if error is ServerKeyChanged || error is PairingClient.WrongMac {
            self.init(title: "This isn't the Mac that showed the code.", primary: .scanAgain)
        } else if error is LocalNetworkDenied {
            self.init(title: "Allow Local Network for Side A Remote to reach \(mac).", primary: .openSettings, secondary: .tryAgain)
        } else if let failure = error as? RemoteFailure {
            self = Self.remote(failure, mac: mac)
        } else if let error = error as? URLError {
            self = await Self.network(error, mac: mac)
            if codeSpent, primary == .tryAgain { primary = .scanNewCode }
        } else if error is DecodingError {
            self.init(title: "Something other than Side A answers at this address.", primary: .scanAgain)
        } else {
            self.init(title: "Pairing didn't finish.", detail: error.localizedDescription, primary: .tryAgain)
        }
    }

    /// Before the code is posted: Remote off, or a version either side must update past.
    init?(_ hello: Hello, macName mac: String, clientBuild: Int) {
        switch hello.needsUpdate(clientBuild: clientBuild) {
        case .client: self.init(title: "Update Side A Remote to pair with this Mac.", primary: .appStore)
        case .mac: self.init(title: "Update Side A on your Mac to 0.6 or later.", primary: .tryAgain)
        case nil:
            guard !hello.remoteOn else { return nil }
            self.init(title: "Turn on Remote in Side A on \(mac).", primary: .tryAgain)
        }
    }

    private static func remote(_ failure: RemoteFailure, mac: String) -> Self {
        switch failure.error.code {
        case .noPairing:
            Self(title: "Click Pair iPhone on your Mac, then scan the new code.", primary: .scanNewCode)
        case .badCode:
            // The code no longer matches: it was replaced on the Mac.
            Self(title: "Scan the current code on your Mac.", primary: .scanNewCode)
        case .codeExpired:
            Self(title: "This code has expired.", primary: .scanNewCode)
        case .codeBusy:
            Self(title: "Another device used this code at the same time.", primary: .scanNewCode)
        case .declined:
            Self(title: "Pairing was cancelled on \(mac).", primary: .scanNewCode)
        case .sasMismatch:
            Self(title: "The codes didn't match, so pairing stopped.", primary: .scanNewCode)
        case .confirmTimeout:
            Self(title: "Nobody clicked Pair on \(mac).", primary: .scanNewCode)
        case .rateLimited:
            Self(title: "Too many tries. Wait a minute.", primary: .tryAgain, retryAfter: failure.retryAfter ?? 60)
        case .upgradeClient:
            Self(title: "Update Side A Remote to pair with this Mac.", primary: .appStore)
        case .upgradeMac:
            Self(title: "Update Side A on your Mac to 0.6 or later.", primary: .tryAgain)
        case .remoteOff:
            Self(title: "Turn on Remote in Side A on \(mac).", primary: .tryAgain)
        default:
            Self(title: failure.error.message, primary: .tryAgain)
        }
    }

    private static func network(_ error: URLError, mac: String) async -> Self {
        let host = error.failingURL?.host() ?? ""
        switch error.code {
        case .cancelled:
            // The pinning delegate cancels a key it can't read; a readable wrong key arrives as ServerKeyChanged.
            return Self(title: "This isn't the Mac that showed the code.", primary: .scanAgain)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            // The key may well be right: this is TLS itself failing, so the code goes in Details.
            let stream = error.userInfo["_kCFStreamErrorCodeKey"] as? Int
            return Self(title: "Couldn't connect securely to \(mac).",
                        detail: "TLS error \(error.code.rawValue)\(stream.map { " (\($0))" } ?? "")", primary: .tryAgain)
        case .cannotConnectToHost:
            return Self(title: "Open Side A on \(mac) and try again.", primary: .tryAgain)
        default:
            if LocalNetwork.denied(error) {
                return Self(title: "Allow Local Network for Side A Remote to reach \(mac).", primary: .openSettings, secondary: .tryAgain)
            }
            if Tailscale.isTailnet(host), Tailscale.installed, await !Tailscale.vpnUp() {
                return Self(title: "Turn on Tailscale on this iPhone.", primary: .openTailscale, secondary: .tryAgain)
            }
            // macOS's firewall drops LAN connections to an app it doesn't know, silently: a timeout, not a refusal.
            if error.code == .timedOut, !Tailscale.isTailnet(host) {
                return Self(title: "Couldn't reach \(mac). Check that your Mac's firewall allows Side A, or open Settings › Remote on your Mac.",
                            primary: .tryAgain)
            }
            return Self(title: "Couldn't reach \(mac).", detail: error.localizedDescription, primary: .tryAgain)
        }
    }
}

/// Local Network privacy (TN3179): a connection to the Wi-Fi refused by the system rather than by the Mac.
enum LocalNetwork {
    /// The failed path's description is the only place iOS says the user turned Local Network off.
    static func denied(_ error: URLError) -> Bool {
        guard let path = error.userInfo["_NSURLErrorNWPathKey"] else { return false }
        return String(describing: path).localizedCaseInsensitiveContains("local network prohibited")
    }
}

/// What the phone can learn about Tailscale: whether the app is there, and whether a VPN is up.
enum Tailscale {
    static let app = URL(string: "tailscale://")!
    static let appStore = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!

    static var installed: Bool { UIApplication.shared.canOpenURL(app) }

    /// A tailnet address: 100.64.0.0/10 or a MagicDNS name. Wi-Fi and loopback addresses don't need Tailscale.
    static func isTailnet(_ host: String) -> Bool {
        if host.hasSuffix(".ts.net") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// A VPN interface shows on the path as `.other`.
    static func vpnUp() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let answered = OSAllocatedUnfairLock(initialState: false)
            monitor.pathUpdateHandler = { path in
                guard answered.withLock({ done in defer { done = true }; return !done }) else { return }
                monitor.cancel()
                continuation.resume(returning: path.availableInterfaces.contains { $0.type == .other })
            }
            monitor.start(queue: .global(qos: .userInitiated))
        }
    }
}
