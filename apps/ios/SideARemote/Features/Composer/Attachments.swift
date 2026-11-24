import ImageIO
import Observation
import SideAProtocol
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DroppedImage: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            guard let prepared = ComposerAttachments.prepare(file: received.file) else { throw CocoaError(.fileReadCorruptFile) }
            return DroppedImage(data: prepared.jpeg)
        }
    }
}

@Observable
final class ComposerAttachments {
    nonisolated deinit {}

    struct Pending: Identifiable {
        enum State: Equatable { case uploading, ready(String), failed(String) }
        let id = UUID()
        var preview: UIImage
        var data: Data
        var state: State
        var refetch: (@MainActor () async -> Data?)?
    }

    private(set) var pending: [SessionKey: [Pending]] = [:]
    @ObservationIgnored private var followed: [UUID: ComposerAttachments] = [:]
    @ObservationIgnored private var uploads: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var uploader: (@MainActor (Data) async throws -> String)?
    private(set) var sent: [String: [UIImage]] = [:]
    @ObservationIgnored weak var tools: MacTools?
    @ObservationIgnored var preparer: @Sendable (Data) async -> (jpeg: Data, preview: UIImage)? = { data in
        await Task.detached(priority: .userInitiated) { ComposerAttachments.prepare(data) }.value
    }

    static let limit = 10
    nonisolated static let longEdge = 2048

    func items(_ session: SessionKey) -> [Pending] { pending[session] ?? [] }
    func isUploading(_ session: SessionKey) -> Bool { items(session).contains { $0.state == .uploading } }
    func room(_ session: SessionKey) -> Int { Self.limit - items(session).count }

    func add(_ data: Data, to session: SessionKey) {
        guard let id = reserve(preview: UIImage(), in: session) else { return }
        Task {
            guard let prepared = await preparer(data) else { return remove(id, from: session) }
            attach(prepared, to: id, in: session)
        }
    }

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

    func reserve(preview: UIImage, in session: SessionKey, refetch: (@MainActor () async -> Data?)? = nil) -> UUID? {
        guard room(session) > 0 else { return nil }
        let item = Pending(preview: preview, data: Data(), state: .uploading, refetch: refetch)
        pending[session, default: []].append(item)
        return item.id
    }

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

    func ready(_ session: SessionKey) -> [String] {
        items(session).compactMap { if case .ready(let id) = $0.state { id } else { nil } }
    }

    enum Gate: Equatable {
        case ready([String])
        case uploading
        case failed
    }

    func gate(_ session: SessionKey) -> Gate {
        if isUploading(session) { return .uploading }
        if hasFailed(session) { return .failed }
        return .ready(ready(session))
    }

    func discard(_ session: SessionKey) { pending[session] = nil }

    func reupload(_ session: SessionKey) {
        for item in items(session) where !item.data.isEmpty {
            set(item.id, in: session, .uploading)
            launch(item.id, in: session)
        }
    }

    func rehome(_ session: SessionKey, to other: ComposerAttachments) {
        guard other !== self else { return }
        let moving = items(session).filter { !$0.data.isEmpty || $0.state == .uploading || $0.refetch != nil }
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

    func take(_ session: SessionKey, for turn: String? = nil) -> [String] {
        let ready = items(session).filter { if case .ready = $0.state { true } else { false } }
        pending[session] = nil
        if let turn, !ready.isEmpty { sent[turn] = ready.map(\.preview) }
        return ready.compactMap { if case .ready(let id) = $0.state { id } else { nil } }
    }

    func giveBack(_ ids: [String], of turn: String, to session: SessionKey) {
        let previews = sent[turn] ?? []
        let have = Set(ready(session))
        for (index, id) in ids.enumerated() where !have.contains(id) && room(session) > 0 {
            pending[session, default: []].append(Pending(preview: previews.indices.contains(index) ? previews[index] : UIImage(), data: Data(),
                                                         state: .ready(id)))
        }
    }

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
                return set(id, in: session, .ready("demo-\(id.uuidString)"))
            }
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

struct AttachmentTray: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: SessionKey
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.tools.attachments.items(session)
        if !items.isEmpty {
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: Space.xs) {
                        ForEach(items) { item in
                            tile(item)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
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
