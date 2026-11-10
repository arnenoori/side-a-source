import AVFoundation
import SideARemoteKit
import SwiftUI
import VisionKit

/// Scan the code on the Mac (setup, "Scan"). A Side A code freezes the frame and the pairing card
/// rises over it; anything else gets a short capsule and the scanner keeps looking.
struct ScannerScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRoot.self) private var root
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var run: PairingRun?
    @State private var notSideA = 0
    @State private var showsNotSideA = false
    @State private var torch = false
    @State private var scannerFailed = false
    @State private var locked = 0
    /// A code for a Mac on another tailnet than one already paired, waiting for Pair Anyway.
    @State private var otherTailnet: OtherTailnet?
    /// A code that may not be from the Mac it names, waiting for Pair Anyway.
    @State private var identity: OtherTailnet?
    @State private var askingDemo = false
    /// "Pair Again with MacBook Pro" when re-pairing.
    var title: String?

    private var supported: Bool { DataScannerViewController.isSupported && !scannerFailed }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch (supported, access) {
                case (true, .authorized):
                    QRScanner(paused: run != nil, found: found, failed: { scannerFailed = true })
                        .ignoresSafeArea()
                    if run == nil { Viewfinder() }
                case (true, .notDetermined):
                    Color.clear.task {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                        access = AVCaptureDevice.authorizationStatus(for: .video)
                    }
                case (true, _):
                    ContentUnavailableView {
                        Label("Camera Access Needed", systemImage: "camera")
                    } description: {
                        Text("Camera access is needed to pair.")
                    } actions: {
                        Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                            .buttonStyle(.glassProminent)
                    }
                default:
                    ContentUnavailableView("Can't Scan Here", systemImage: "qrcode.viewfinder")
                }

                if let run {
                    Color.black.opacity(0.35).ignoresSafeArea().transition(.opacity)
                    PairingCard(run: run) { withAnimation(Motion.smooth(reduceMotion)) { self.run = nil } }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .top) {
                if run == nil, supported, access == .authorized {
                    Text("Scan the code in Side A › Settings › Remote.")
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Space.xl)
                        .padding(.top, Space.s)
                }
            }
            .overlay(alignment: .bottom) {
                if showsNotSideA {
                    Text("That isn't a Side A pairing code.")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.s)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 120)
                        .transition(.opacity)
                        .task(id: notSideA) {
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation(Motion.smooth(reduceMotion)) { showsNotSideA = false }
                        }
                }
            }
            .navigationTitle(run == nil ? title ?? "" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { run?.cancel(); dismiss() }
                }
                if run == nil, supported, access == .authorized, Torch.available {
                    ToolbarItem(placement: .primaryAction) {
                        Button(torch ? "Turn Off Light" : "Turn On Light", systemImage: torch ? "flashlight.on.fill" : "flashlight.off.fill") {
                            torch.toggle()
                        }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        .sensoryFeedback(.warning, trigger: notSideA)
        .sensoryFeedback(.success, trigger: locked)
        .onChange(of: torch, initial: false) { _, on in Torch.set(on) }
        .onChange(of: run == nil) { _, scanning in if !scanning, torch { torch = false } }
        .onDisappear { if torch { Torch.set(false) } }
        .alert(otherTailnet?.title ?? "", isPresented: Binding { otherTailnet != nil } set: { if !$0 { otherTailnet = nil } },
               presenting: otherTailnet) { warning in
            Button("Pair Anyway") {
                otherTailnet = nil
                pair(warning.invitation)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(OtherTailnet.message)
        }
        .alert(identity?.title ?? "", isPresented: Binding { identity != nil } set: { if !$0 { identity = nil } },
               presenting: identity) { warning in
            Button("Pair Anyway", role: .destructive) {
                identity = nil
                proceed(warning.invitation)
            }
            Button("Cancel", role: .cancel) {}
        }
        .demoConfirmation(isPresented: $askingDemo) {
            root.openDemo()
            dismiss()
        }
        // Back from Settings with the camera allowed: scan without reopening.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { access = AVCaptureDevice.authorizationStatus(for: .video) }
        }
    }

    private func found(_ payload: String) {
        // The camera keeps reading the code behind an alert; a re-read must not skip its Pair Anyway.
        guard run == nil, identity == nil, otherTailnet == nil else { return }
        if let url = URL(string: payload), ReviewDemo.matches(url) {
            locked += 1
            guard root.action(for: url) == .openDemo else { return askingDemo = true }
            root.openDemo()
            return dismiss()
        }
        guard let url = URL(string: payload), let invitation = PairingLink.invitation(url) else {
            if !showsNotSideA {
                notSideA += 1
                withAnimation(Motion.smooth(reduceMotion)) { showsNotSideA = true }
            }
            return
        }
        locked += 1
        if let warning = PairedMac.identityWarning(invitation) {
            identity = OtherTailnet(invitation: invitation, title: warning)
            return
        }
        proceed(invitation)
    }

    private func proceed(_ invitation: PairingClient.Invitation) {
        let name = invitation.macName ?? "This Mac"
        if otherTailnet == nil, let other = PairedMac.otherTailnet(invitation) {
            otherTailnet = OtherTailnet(invitation: invitation, title: "\(name) is on a different tailnet from \(other.endpoint.name).")
            return
        }
        pair(invitation)
    }

    private func pair(_ invitation: PairingClient.Invitation) {
        let run = PairingRun(invitation: invitation)
        withAnimation(Motion.smooth(reduceMotion)) { self.run = run }
        run.start(replacing: PairedMac.matching(invitation))
    }
}

/// Two Macs on different tailnets, and no relay to reach across them.
struct OtherTailnet: Identifiable {
    let invitation: PairingClient.Invitation
    let title: String
    var id: String { title }
    static let message = "Your iPhone reaches one tailnet at a time, so only one of them will connect."
}

/// The back camera's light, for a code on a dim screen.
private enum Torch {
    static var available: Bool { AVCaptureDevice.default(for: .video)?.hasTorch == true }

    static func set(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch, (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }
}

/// The corners of the scanning frame.
private struct Viewfinder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [44, 1000], dashPhase: 22))
            .frame(width: 250, height: 250)
            .accessibilityHidden(true)
    }
}

/// VisionKit's scanner, QR codes only.
private struct QRScanner: UIViewControllerRepresentable {
    let paused: Bool
    let found: (String) -> Void
    /// The camera wouldn't start (in use elsewhere, or restricted).
    let failed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isHighlightingEnabled: false)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.found = found
        if paused {
            scanner.stopScanning()
        } else if !scanner.isScanning {
            do { try scanner.startScanning() } catch { DispatchQueue.main.async(execute: failed) }
        }
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        nonisolated deinit {}

        var found: (String) -> Void
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in addedItems {
                if let payload = code.payloadStringValue { found(payload) }
            }
        }
    }
}

/// A pairing link in exactly the Mac's two forms, `sidea-remote://pair#…` and `https://getsidea.com/pair#…`, carrying
/// the Mac's key hash: without one the connection can't be pinned, and the 6 digits alone could be ground by a
/// machine in the middle.
enum PairingLink {
    /// One of the two forms, with nothing beside the fragment: no user, port or query.
    static func isForm(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased(), host = url.host()?.lowercased()
        let form = (scheme == "sidea-remote" && host == "pair" && ["", "/"].contains(url.path()))
            || (scheme == "https" && host == "getsidea.com" && ["/pair", "/pair/"].contains(url.path()))
        return form && url.user() == nil && url.port == nil && url.query() == nil
    }

    static func invitation(_ url: URL) -> PairingClient.Invitation? {
        guard isForm(url), let invitation = PairingClient.Invitation(url: url), !invitation.fp.isEmpty,
              !invitation.code.isEmpty, invitation.addresses.allSatisfy({ !$0.hasPrefix(":") }) else { return nil }
        return invitation
    }
}
