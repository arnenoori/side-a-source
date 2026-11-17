import ImageIO
import Observation
import SideAProtocol
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// An image dropped on the composer, in whatever format the source app offers, already cut to the upload's size. It's
/// read from the file it arrives as, never decoded whole, so a RAW or a huge TIFF costs what a photo does.
struct DroppedImage: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            guard let prepared = ComposerAttachments.prepare(file: received.file) else { throw CocoaError(.fileReadCorruptFile) }
            return DroppedImage(data: prepared.jpeg)
        }
    }
}

/// Photos waiting to go with a session's next reply: each one downscaled to 2048 px on
/// its long edge, re-encoded as JPEG (which drops EXIF and turns HEIC into something every agent
/// reads), and uploaded at once; the reply carries the Mac's upload ids. The demo keeps them here.
@Observable
final class ComposerAttachments {
    nonisolated deinit {}

    struct Pending: Identifiable {
        enum State: Equatable { case uploading, ready(String), failed(String) }
        let id = UUID()
        var preview: UIImage
        var data: Data
        var state: State
        /// Fetches the photo again, for a drawer pick whose bytes never arrived.
        var refetch: (@MainActor () async -> Data?)?
    }

    private(set) var pending: [SessionKey: [Pending]] = [:]
    /// Tiles that moved to another Mac's tray while their photo was still being prepared or fetched. What arrives for them
    /// here, from the task that was preparing it or the drawer that was fetching it, goes on to that tray.
    @ObservationIgnored private var followed: [UUID: ComposerAttachments] = [:]
    /// Each photo's upload to this tray's Mac while it runs, so moving the tile to another Mac's tray can stop it.
    @ObservationIgnored private var uploads: [UUID: Task<Void, Never>] = [:]
    /// Sends a photo to this tray's Mac and answers its upload id; a test stands in for the Mac with it.
    @ObservationIgnored var uploader: (@MainActor (Data) async throws -> String)?
    /// What each sent turn carried, shown on its bubble until the Mac's copy of the turn replaces it.
    private(set) var sent: [String: [UIImage]] = [:]
    @ObservationIgnored weak var tools: MacTools?
    /// Cuts a photo to the upload's size off the main actor; a test holds it to see the tray while a photo is still being prepared.
    @ObservationIgnored var preparer: @Sendable (Data) async -> (jpeg: Data, preview: UIImage)? = { data in
        await Task.detached(priority: .userInitiated) { ComposerAttachments.prepare(data) }.value
    }

    /// The Mac takes ten per reply.
    static let limit = 10
    nonisolated static let longEdge = 2048

    func items(_ session: SessionKey) -> [Pending] { pending[session] ?? [] }
    func isUploading(_ session: SessionKey) -> Bool { items(session).contains { $0.state == .uploading } }
    func room(_ session: SessionKey) -> Int { Self.limit - items(session).count }

    /// From the picker, the camera, Files or the pasteboard. The tile is in the tray, uploading, before the photo is cut
    /// down, so a Start or a Send in that while waits for it. Anything that isn't an image is skipped.
    func add(_ data: Data, to session: SessionKey) {
        guard let id = reserve(preview: UIImage(), in: session) else { return }
        Task {
            guard let prepared = await preparer(data) else { return remove(id, from: session) }
            attach(prepared, to: id, in: session)
        }
    }

    /// The prepared photo onto its tile, which is gone if the tray was cleared or the tile removed meanwhile, then up it goes.
    private func attach(_ prepared: (jpeg: Data, preview: UIImage), to id: UUID, in session: SessionKey) {
        if let other = followed.removeValue(forKey: id) { return other.attach(prepared, to: id, in: session) }
        guard let index = pending[session]?.firstIndex(where: { $0.id == id }) else { return }
        pending[session]?[index].preview = prepared.preview
        pending[session]?[index].data = prepared.jpeg
        launch(id, in: session)
    }

    private func launch(_ id: UUID, in session: SessionKey) {
        uploads[id]?.cancel()
        uploads[id] = Task { await upload(id, in: session) }
    }

    /// A photo the drawer is still fetching: its tile shows `preview` now, goes up once `supply` has the bytes,
    /// and the reply waits for it like any upload. Nil when the tray is full.
    func reserve(preview: UIImage, in session: SessionKey, refetch: (@MainActor () async -> Data?)? = nil) -> UUID? {
        guard room(session) > 0 else { return nil }
        let item = Pending(preview: preview, data: Data(), state: .uploading, refetch: refetch)
        pending[session, default: []].append(item)
        return item.id
    }

    /// The bytes for a reserved photo; what can't be read as an image marks the tile failed.
    func supply(_ id: UUID, _ data: Data?, in session: SessionKey) {
        if let other = followed.removeValue(forKey: id) { return other.supply(id, data, in: session) }
        guard items(session).contains(where: { $0.id == id }) else { return }
        guard let data else { return fail(id, "The photo couldn't be loaded.", in: session) }
        Task {
            guard let prepared = await preparer(data) else { return fail(id, "The photo couldn't be read.", in: session) }
            attach(prepared, to: id, in: session)
        }
    }

    func fail(_ id: UUID, _ reason: String, in session: SessionKey) {
        if let other = followed.removeValue(forKey: id) { return other.fail(id, reason, in: session) }
        set(id, in: session, .failed(reason))
    }

    func remove(_ id: UUID, from session: SessionKey) {
        if let other = followed.removeValue(forKey: id) { return other.remove(id, from: session) }
        pending[session]?.removeAll { $0.id == id }
    }

    func retry(_ id: UUID, in session: SessionKey) {
        guard let item = items(session).first(where: { $0.id == id }) else { return }
        guard !item.data.isEmpty else {
            // Never fetched: fetch again if the tile knows how, otherwise there is nothing to send and the tile goes.
            guard let refetch = item.refetch else { return remove(id, from: session) }
            set(id, in: session, .uploading)
            Task { supply(id, await refetch(), in: session) }
            return
        }
        set(id, in: session, .uploading)
        launch(id, in: session)
    }

    func hasFailed(_ session: SessionKey) -> Bool {
        items(session).contains { if case .failed = $0.state { true } else { false } }
    }

    /// The ids of the photos on the Mac, in order, with the tray left as it is: a request that may fail takes these,
    /// and `take` once it has gone.
    func ready(_ session: SessionKey) -> [String] {
        items(session).compactMap { if case .ready(let id) = $0.state { id } else { nil } }
    }

    /// Whether a request that names the tray's photos can go now.
    enum Gate: Equatable {
        case ready([String])
        /// A photo is still on its way: the request waits.
        case uploading
        /// A photo didn't go up: the request waits for Retry or Remove, rather than leaving it out.
        case failed
    }

    func gate(_ session: SessionKey) -> Gate {
        if isUploading(session) { return .uploading }
        if hasFailed(session) { return .failed }
        return .ready(ready(session))
    }

    /// The tray emptied without sending: the screen it belonged to is gone.
    func discard(_ session: SessionKey) { pending[session] = nil }

    /// Every photo that was on the Mac goes up again, for a Mac that no longer has them (it clears uploads after a week).
    func reupload(_ session: SessionKey) {
        for item in items(session) where !item.data.isEmpty {
            set(item.id, in: session, .uploading)
            launch(item.id, in: session)
        }
    }

    /// The tray under `session` moves to another Mac's, which has none of these photos: each goes up to that Mac. A photo
    /// still being prepared, or fetched by the drawer, moves as it is and goes up to that Mac once it is ready: what its task
    /// or the drawer reports to this tray is passed on.
    func rehome(_ session: SessionKey, to other: ComposerAttachments) {
        guard other !== self else { return }
        let moving = items(session).filter { !$0.data.isEmpty || $0.state == .uploading || $0.refetch != nil }
        // What is on its way to this Mac goes to the other one only. An upload that had already finished leaves a copy here
        // that the Mac clears with the week's other uploads.
        for item in items(session) { uploads.removeValue(forKey: item.id)?.cancel() }
        pending[session] = nil
        for item in moving.prefix(other.room(session)) {
            var again = item
            if !item.data.isEmpty { again.state = .uploading }
            else if item.state == .uploading { followed[item.id] = other }
            other.pending[session, default: []].append(again)
            if !item.data.isEmpty { other.launch(again.id, in: session) }
        }
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
        do {
            let uploaded: String
            if let uploader {
                uploaded = try await uploader(item.data)
            } else if let tools, !tools.isDemo {
                uploaded = try await tools.upload(item.data, mime: "image/jpeg").id
            } else {
                // The demo keeps the photo and sends nothing.
                return set(id, in: session, .ready("demo-\(id.uuidString)"))
            }
            // Moved to another Mac's tray meanwhile: this answer is for the Mac it left.
            guard !Task.isCancelled else { return }
            set(id, in: session, .ready(uploaded))
        } catch {
            guard !Task.isCancelled else { return }
            set(id, in: session, .failed(MacTools.message(error)))
        }
    }

    private func set(_ id: UUID, in session: SessionKey, _ state: Pending.State) {
        guard let index = pending[session]?.firstIndex(where: { $0.id == id }) else { return }
        pending[session]?[index].state = state
    }

    /// Downscaled and re-encoded; nil for bytes ImageIO can't read as an image.
    nonisolated static func prepare(_ data: Data) -> (jpeg: Data, preview: UIImage)? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(prepare(source:))
    }

    nonisolated static func prepare(file: URL) -> (jpeg: Data, preview: UIImage)? {
        CGImageSourceCreateWithURL(file as CFURL, nil).flatMap(prepare(source:))
    }

    private nonisolated static func prepare(source: CGImageSource) -> (jpeg: Data, preview: UIImage)? {
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
    /// Tiles the drawer's flying copies are about to land on: blank until they have.
    var landing: Set<UUID> = []
    /// Where each tile is in the window, for the copies to land on.
    var report: (UUID, CGRect) -> Void = { _, _ in }
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.tools.attachments.items(session)
        if !items.isEmpty {
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: Space.xs) {
                        ForEach(items) { item in
                            tile(item)
                                .opacity(landing.contains(item.id) ? 0 : 1)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { report(item.id, $0) }
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, Space.xxs)
                    .padding(.vertical, Space.xxs)
                }
                .onChange(of: items.last?.id) { _, last in
                    guard let last else { return }
                    withAnimation(Motion.smooth(reduceMotion)) { reader.scrollTo(last, anchor: .trailing) }
                }
            }
            .scrollIndicators(.hidden)
            .transition(.opacity)
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
                case .failed where item.data.isEmpty && item.refetch == nil:
                    // Never fetched and nothing to fetch it with: the tile only goes.
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.5))
                    Image(systemName: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.white)
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
                        // Up only as far as the tray's own padding, which clips what sticks out above.
                        .hitArea(top: 4, leading: 11, bottom: 18, trailing: 11)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
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
        nonisolated deinit {}

        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.95) { parent.onPhoto(data) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
