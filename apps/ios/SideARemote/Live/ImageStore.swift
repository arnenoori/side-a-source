import CryptoKit
import SideAProtocol
import SideARemoteShared
import SwiftUI
import UIKit

/// Session images for the tiles and the viewer: memory first, then the App Group's disk cache, then
/// the Mac. One fetch per id at a time, however many views ask.
@MainActor
final class ImageStore {
    nonisolated deinit {}

    typealias Fetch = @Sendable (_ id: String, _ thumbnail: Bool) async throws -> Data

    /// Nil in the demo, which draws its images instead.
    var fetch: Fetch?
    private let isDemo: Bool
    private let disk: ImageCache
    private let memory = NSCache<NSString, UIImage>()
    private var loading: [String: Task<UIImage?, Never>] = [:]

    init(isDemo: Bool, disk: ImageCache = .shared) {
        self.isDemo = isDemo; self.disk = disk
        memory.totalCostLimit = 96 * 1024 * 1024
        // Every Mac's model and the demo share the folder: one scan a launch is enough.
        if Self.trimmed.insert(disk.folder).inserted {
            Task.detached(priority: .background) { disk.trim() }
        }
    }

    private static var trimmed: Set<URL> = []

    /// Already decoded, for the first frame of a view.
    func cached(_ ref: ImageRef, thumbnail: Bool) -> UIImage? {
        if isDemo { return DemoImages.image(for: ref) }
        return memory.object(forKey: key(ref.id, thumbnail))
    }

    func image(_ ref: ImageRef, thumbnail: Bool) async -> UIImage? {
        if let image = cached(ref, thumbnail: thumbnail) { return image }
        let key = key(ref.id, thumbnail)
        if let task = loading[key as String] { return await task.value }
        let task = Task { [disk, fetch] () -> UIImage? in
            let id = ref.id
            let data: Data? = await Task.detached { disk.data(id, thumbnail: thumbnail) }.value
            if let data, let image = await Self.decode(data) { return image }
            guard let fetch, let fresh = try? await fetch(id, thumbnail) else { return nil }
            guard let image = await Self.decode(fresh) else { return nil }
            await Task.detached(priority: .utility) { disk.store(fresh, id, thumbnail: thumbnail) }.value
            return image
        }
        loading[key as String] = task
        let image = await task.value
        loading[key as String] = nil
        if let image { memory.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4)) }
        return image
    }

    /// The original bytes, for Share and Save to keep the file's own format.
    func data(_ ref: ImageRef) async -> Data? {
        if isDemo { return DemoImages.image(for: ref)?.pngData() }
        let id = ref.id
        if let data = await Task.detached(operation: { [disk] in disk.data(id, thumbnail: false) }).value { return data }
        guard let fetch, let fresh = try? await fetch(id, false), UIImage(data: fresh) != nil else { return nil }
        await Task.detached { [disk] in disk.store(fresh, id, thumbnail: false) }.value
        return fresh
    }

    /// Bytes fetched some other way, kept under their SHA-1 as the Mac's images are, so the viewer can show them.
    func keep(_ data: Data, mime: String, name: String) async -> ImageRef? {
        guard let image = await Self.decode(data) else { return nil }
        let id = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        memory.setObject(image, forKey: key(id, false), cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        await Task.detached(priority: .utility) { [disk] in disk.store(data, id, thumbnail: false) }.value
        return ImageRef(id: id, mime: mime, bytes: data.count, width: Int(image.size.width * image.scale), height: Int(image.size.height * image.scale),
                        source: .other, name: name)
    }

    private func key(_ id: String, _ thumbnail: Bool) -> NSString { (id + (thumbnail ? ".thumb" : "")) as NSString }

    private nonisolated static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { UIImage(data: data)?.preparingForDisplay() }.value
    }
}

/// An image from the session, the thumbnail or the original; a quiet glyph until it arrives.
struct SessionImage: View {
    let ref: ImageRef
    var thumbnail = true
    @Environment(AppModel.self) private var model
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image ?? model.images.cached(ref, thumbnail: thumbnail) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: ref.id) { image = await model.images.image(ref, thumbnail: thumbnail) }
    }
}
