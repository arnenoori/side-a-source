import ImageIO
import Observation
import SideAProtocol
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Photos waiting to go with a session's next reply (section 4.4): each one downscaled to 2048 px on
/// its long edge, re-encoded as JPEG (which drops EXIF and turns HEIC into something every agent
/// reads), and uploaded at once; the reply carries the Mac's upload ids. The demo keeps them here.
@Observable
final class ComposerAttachments {
    struct Pending: Identifiable {
        enum State: Equatable { case uploading, ready(String), failed(String) }
        let id = UUID()
        let preview: UIImage
        let data: Data
        var state: State
    }

    private(set) var pending: [SessionKey: [Pending]] = [:]
    /// What each sent turn carried, shown on its bubble until the Mac's copy of the turn replaces it.
    private(set) var sent: [String: [UIImage]] = [:]
    @ObservationIgnored weak var tools: MacTools?

    /// The Mac takes ten per reply.
    static let limit = 10
    nonisolated static let longEdge = 2048

    func items(_ session: SessionKey) -> [Pending] { pending[session] ?? [] }
    func isUploading(_ session: SessionKey) -> Bool { items(session).contains { $0.state == .uploading } }
    func room(_ session: SessionKey) -> Int { Self.limit - items(session).count }

    /// From the picker, the camera, Files or the pasteboard. Anything that isn't an image is skipped.
    func add(_ data: Data, to session: SessionKey) {
        guard room(session) > 0 else { return }
        Task {
            guard let prepared = await Task.detached(priority: .userInitiated, operation: { Self.prepare(data) }).value else { return }
            let item = Pending(preview: prepared.preview, data: prepared.jpeg, state: .uploading)
            pending[session, default: []].append(item)
            await upload(item.id, in: session)
        }
    }

    func remove(_ id: UUID, from session: SessionKey) {
        pending[session]?.removeAll { $0.id == id }
    }

    func retry(_ id: UUID, in session: SessionKey) {
        set(id, in: session, .uploading)
        Task { await upload(id, in: session) }
    }

    /// The ids for a reply about to go, and the tray cleared; `turn` keeps the photos on its bubble.
    func take(_ session: SessionKey, for turn: String? = nil) -> [String] {
        let ready = items(session).filter { if case .ready = $0.state { true } else { false } }
        pending[session] = nil
        if let turn, !ready.isEmpty { sent[turn] = ready.map(\.preview) }
        return ready.compactMap { if case .ready(let id) = $0.state { id } else { nil } }
    }

    /// A retried reply's photos, onto the turn that now carries them.
    func carry(from turn: String, to next: String) {
        guard turn != next, let photos = sent.removeValue(forKey: turn) else { return }
        sent[next] = photos
    }

    private func upload(_ id: UUID, in session: SessionKey) async {
        guard let item = items(session).first(where: { $0.id == id }) else { return }
        guard let tools, tools.isLive else {
            // The demo keeps the photo and sends nothing.
            set(id, in: session, .ready("demo-\(id.uuidString)"))
            return
        }
        do {
            let upload = try await tools.upload(item.data, mime: "image/jpeg")
            set(id, in: session, .ready(upload.id))
        } catch {
            set(id, in: session, .failed(MacTools.message(error)))
        }
    }

    private func set(_ id: UUID, in session: SessionKey, _ state: Pending.State) {
        guard let index = pending[session]?.firstIndex(where: { $0.id == id }) else { return }
        pending[session]?[index].state = state
    }

    /// Downscaled and re-encoded; nil for bytes ImageIO can't read as an image.
    nonisolated static func prepare(_ data: Data) -> (jpeg: Data, preview: UIImage)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: longEdge]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, UIImage(cgImage: image))
    }
}

/// The photos above the field: each with its upload's progress, a remove button, and Retry when it failed.
struct AttachmentTray: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: SessionKey
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.tools.attachments.items(session)
        if !items.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: Space.xs) {
                    ForEach(items) { item in tile(item) }
                }
                .padding(.horizontal, Space.xxs)
                .padding(.vertical, Space.xxs)
            }
            .scrollIndicators(.hidden)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func tile(_ item: ComposerAttachments.Pending) -> some View {
        Image(uiImage: item.preview)
            .resizable()
            .scaledToFill()
            .frame(width: 64, height: 64)
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .overlay {
                switch item.state {
                case .uploading:
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.35))
                    ProgressView().tint(.white)
                case .failed:
                    Button { model.tools.attachments.retry(item.id, in: session) } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.5))
                            Image(systemName: "arrow.clockwise").font(.headline).foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retry upload")
                case .ready:
                    EmptyView()
                }
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation(Motion.snappy(reduceMotion)) { model.tools.attachments.remove(item.id, from: session) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .frame(width: 22, height: 22)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .padding(3)
                .accessibilityLabel("Remove photo")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label(item.state))
    }

    private func label(_ state: ComposerAttachments.Pending.State) -> String {
        switch state {
        case .uploading: "Photo, uploading"
        case .ready: "Photo"
        case .failed(let reason): "Photo, not uploaded. \(reason)"
        }
    }
}

/// The camera, where the device has one.
struct CameraPicker: UIViewControllerRepresentable {
    let onPhoto: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.95) { parent.onPhoto(data) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
