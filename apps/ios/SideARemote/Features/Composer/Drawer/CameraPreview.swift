import AVFoundation
import Observation
import SideARemoteShared
import SwiftUI
import UIKit

/// What the viewfinder can do with the flash, in the order the button cycles through them.
enum CaptureFlash: String, CaseIterable, Equatable {
    case auto, on, off

    var next: CaptureFlash {
        switch self {
        case .auto: .on
        case .on: .off
        case .off: .auto
        }
    }

    var symbol: String {
        switch self {
        case .auto: "bolt.badge.automatic.fill"
        case .on: "bolt.fill"
        case .off: "bolt.slash.fill"
        }
    }

    var title: String { rawValue.capitalized }

    var mode: AVCaptureDevice.FlashMode {
        switch self {
        case .auto: .auto
        case .on: .on
        case .off: .off
        }
    }
}

/// Where pictures come from: the device's camera, or in a debug build or a test a stand-in, so everything around it
/// (the viewfinder's layout and motion, a capture arriving in the tray) can be seen and tested without a camera.
@MainActor
protocol CaptureSource: AnyObject {
    /// The running session, for a preview layer; nil for a stand-in.
    var session: AVCaptureSession? { get }
    /// What a stand-in's viewfinder shows.
    var testFrame: UIImage? { get }
    var hasFront: Bool { get }
    func hasFlash(front: Bool) -> Bool
    /// The camera was taken away (a call, another app, multitasking on an iPad) or came back.
    var onInterruption: ((Bool) -> Void)? { get set }
    func start(front: Bool)
    func stop()
    func setZoom(_ factor: CGFloat)
    /// A photo as JPEG, turned upright for `angle`; nil when none could be taken.
    func capture(angle: CGFloat, flash: CaptureFlash) async -> Data?
}

/// The device camera. All AVFoundation work is on one queue: starting a session blocks, and nothing here may stall the
/// main thread. A device without a camera (the simulator) has no session at all, and nothing is logged for that.
final class CameraCapture: CaptureSource, @unchecked Sendable {
    nonisolated deinit {}

    private let runner: SessionRunner?
    var onInterruption: ((Bool) -> Void)?

    static var hasCamera: Bool { AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil }

    init() {
        runner = SessionRunner()
        runner?.onInterruption = { [weak self] interrupted in
            Task { @MainActor in self?.onInterruption?(interrupted) }
        }
    }

    var session: AVCaptureSession? { runner?.session }
    var testFrame: UIImage? { nil }
    var hasFront: Bool { AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil }

    func hasFlash(front: Bool) -> Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back)?.hasFlash ?? false
    }

    func start(front: Bool) { runner?.start(front: front) }
    func stop() { runner?.stop() }
    func setZoom(_ factor: CGFloat) { runner?.setZoom(factor) }

    func capture(angle: CGFloat, flash: CaptureFlash) async -> Data? {
        guard let runner else { return nil }
        return await runner.capture(angle: angle, flash: flash.mode)
    }
}

/// The session, its photo output and the queue they live on.
nonisolated final class SessionRunner: @unchecked Sendable {
    let session = AVCaptureSession()
    var onInterruption: (@Sendable (Bool) -> Void)?
    private let queue = DispatchQueue(label: "SideARemote.camera.session", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private var positioned: AVCaptureDevice.Position?
    private var device: AVCaptureDevice?
    private var pending: [PhotoCatcher] = []
    private var observers: [NSObjectProtocol] = []

    init?() {
        guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil else { return nil }
        let center = NotificationCenter.default
        let names: [(Notification.Name, Bool)] = [(AVCaptureSession.wasInterruptedNotification, true),
                                                  (AVCaptureSession.interruptionEndedNotification, false),
                                                  (AVCaptureSession.runtimeErrorNotification, true)]
        for (name, interrupted) in names {
            observers.append(center.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in self?.onInterruption?(interrupted) })
        }
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func start(front: Bool) {
        queue.async { [self] in
            guard configure(position: front ? .front : .back) else { return }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func setZoom(_ factor: CGFloat) {
        queue.async { [self] in
            guard let device else { return }
            let clamped = min(max(factor, device.minAvailableVideoZoomFactor), min(device.maxAvailableVideoZoomFactor, 6))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
            } catch {
                RemoteLog.error(.app, "The camera's zoom couldn't be set: \(error)")
            }
        }
    }

    func capture(angle: CGFloat, flash: AVCaptureDevice.FlashMode) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            queue.async { [self] in
                guard session.isRunning else { return continuation.resume(returning: nil) }
                if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                if output.supportedFlashModes.contains(flash) { settings.flashMode = flash }
                let catcher = PhotoCatcher { [weak self] data in
                    continuation.resume(returning: data)
                    self?.queue.async { self?.pending.removeAll { $0.settled } }
                }
                pending.append(catcher)
                output.capturePhoto(with: settings, delegate: catcher)
            }
        }
    }

    /// Puts the camera for `position` on the session, once; false when there is none or it can't be used.
    private func configure(position: AVCaptureDevice.Position) -> Bool {
        if positioned == position { return true }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: camera) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        for existing in session.inputs { session.removeInput(existing) }
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
        device = camera
        positioned = position
        return true
    }
}

/// Receives one photo and hands over its bytes.
private nonisolated final class PhotoCatcher: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let finish: @Sendable (Data?) -> Void
    private(set) var settled = false

    init(finish: @escaping @Sendable (Data?) -> Void) { self.finish = finish }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        settled = true
        if let error { RemoteLog.error(.app, "A photo couldn't be taken: \(error)") }
        finish(error == nil ? photo.fileDataRepresentation() : nil)
    }
}

#if DEBUG
/// `--fake-camera`: a picture where the camera would be, so a simulator can show the tile, the viewfinder and a capture.
final class FakeCapture: CaptureSource {
    nonisolated deinit {}

    var onInterruption: ((Bool) -> Void)?
    var session: AVCaptureSession? { nil }
    var hasFront: Bool { true }
    private(set) var started = 0
    private(set) var stopped = 0
    private(set) var zoom: CGFloat = 1
    let testFrame: UIImage? = FakeCapture.picture()

    func hasFlash(front: Bool) -> Bool { !front }
    func start(front: Bool) { started += 1 }
    func stop() { stopped += 1 }
    func setZoom(_ factor: CGFloat) { zoom = factor }

    func capture(angle: CGFloat, flash: CaptureFlash) async -> Data? { testFrame?.jpegData(compressionQuality: 0.9) }

    private static func picture() -> UIImage {
        let size = CGSize(width: 600, height: 800)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(hue: 0.58, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor,
                          UIColor(hue: 0.08, saturation: 0.6, brightness: 0.95, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            UIColor.white.withAlphaComponent(0.85).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 180, y: 260, width: 240, height: 240))
        }
    }
}
#endif

/// The camera's state around the tile and the viewfinder: whether it may be shown, asked for or opened, and what the
/// viewfinder is doing.
@MainActor @Observable
final class CameraModel {
    nonisolated deinit {}

    private(set) var access: CameraAccess
    /// The viewfinder is open: the panel has grown around the tile's preview.
    private(set) var shooting = false
    /// The viewfinder is on screen, open or still shrinking back into the tile.
    private(set) var showsViewfinder = false
    private(set) var front = false
    private(set) var flash = CaptureFlash.auto
    private(set) var capturing = false
    /// The camera was taken away (a call, another app, multitasking): the tile and viewfinder show a glyph, not a frozen frame.
    private(set) var interrupted = false
    private(set) var zoom: CGFloat = 1
    @ObservationIgnored let source: CaptureSource?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var hiding: Task<Void, Never>?

    init(source: CaptureSource? = CameraModel.makeSource()) {
        self.source = source
        access = Self.access(for: source)
        source?.onInterruption = { [weak self] interrupted in self?.interrupted = interrupted }
    }

    /// The device's camera, a stand-in under `--fake-camera`, or none where there is no camera.
    static func makeSource() -> CaptureSource? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--fake-camera") { return FakeCapture() }
        #endif
        return CameraCapture.hasCamera ? CameraCapture() : nil
    }

    private static func access(for source: CaptureSource?) -> CameraAccess {
        #if DEBUG
        if source is FakeCapture { return .authorized }
        #endif
        return CameraAccess(AVCaptureDevice.authorizationStatus(for: .video), hasCamera: source != nil)
    }

    var hasCamera: Bool { source != nil }
    var hasFlash: Bool { source?.hasFlash(front: front) ?? false }
    var canFlip: Bool { source?.hasFront ?? false }
    /// The tile is live and can be opened.
    var isLive: Bool { access.showsPreview && !interrupted }

    /// The drawer opened: look at the permission as it is now, and run the preview if it may run.
    func start() {
        wanted = true
        refresh()
    }

    /// The drawer closed or the app left the foreground.
    func stop() {
        wanted = false
        hiding?.cancel()
        shooting = false
        showsViewfinder = false
        capturing = false
        interrupted = false
        front = false
        zoom = 1
        source?.stop()
    }

    func refresh() {
        access = Self.access(for: source)
        if wanted, access.showsPreview { source?.start(front: front) }
    }

    /// The first tap: the system's question. Granted, the tile turns live where it is.
    func ask() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        refresh()
    }

    func open() {
        hiding?.cancel()
        showsViewfinder = true
        shooting = true
    }

    /// Back into the tile; the viewfinder stays up until it has finished shrinking.
    func close() {
        shooting = false
        zoom = 1
        source?.setZoom(1)
        hiding?.cancel()
        hiding = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled else { return }
            self?.showsViewfinder = false
        }
    }

    func flip() {
        guard canFlip else { return }
        front.toggle()
        zoom = 1
        source?.start(front: front)
    }

    func cycleFlash() { flash = flash.next }

    func setZoom(_ factor: CGFloat) {
        zoom = min(max(factor, 1), 6)
        source?.setZoom(zoom)
    }

    /// One photo; nil if the camera couldn't take it. One at a time.
    func capture(angle: CGFloat) async -> Data? {
        guard let source, !capturing, shooting else { return nil }
        capturing = true
        defer { capturing = false }
        return await source.capture(angle: angle, flash: front ? .off : flash)
    }

    func setInterrupted(_ value: Bool) { interrupted = value }
}

/// What the camera sees, filling its tile or the viewfinder.
struct LivePreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        // swiftlint:disable:next force_cast -- layerClass above is what makes the layer this class
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let connection = previewLayer.connection, let orientation = window?.windowScene?.interfaceOrientation else { return }
            let angle = CameraAccess.previewAngle(for: orientation)
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }
}

/// The picture in the tile and the viewfinder: the camera's, or a stand-in's.
struct CameraSurface: View {
    let camera: CameraModel

    var body: some View {
        if camera.interrupted {
            ZStack {
                Color(.tertiarySystemFill)
                Image(systemName: "camera.fill").font(.title2).foregroundStyle(.secondary)
            }
        } else if let frame = camera.source?.testFrame {
            // A picture that overflows would size the tile to itself; it only fills it.
            Color.clear.overlay { Image(uiImage: frame).resizable().scaledToFill() }.clipped()
        } else if let session = camera.source?.session {
            LivePreview(session: session)
        } else {
            Color(.tertiarySystemFill)
        }
    }
}
