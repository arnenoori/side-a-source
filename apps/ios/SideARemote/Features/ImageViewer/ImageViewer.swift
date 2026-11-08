import Photos
import SideAProtocol
import UniformTypeIdentifiers
import SideARemoteShared
import SwiftUI
import UIKit

/// Photos-style viewer: zooms out of its tile, pages through the session's images,
/// pinch and double-tap zoom in a real `UIScrollView`, and drag down to send it back.
struct ImageViewer: View {
    let images: [ImageRef]
    @State private var current: String?
    @State private var chrome = true
    @State private var copies = 0
    @State private var hud: String?
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(images: [ImageRef], start: String) {
        self.images = images
        current = start
    }

    private var index: Int { images.firstIndex { $0.id == current } ?? 0 }
    private var image: ImageRef { images[index] }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(images) { ref in
                    ViewerPage(ref: ref) {
                        withAnimation(Motion.smooth(reduceMotion)) { chrome.toggle() }
                    }
                    .containerRelativeFrame(.horizontal)
                    .id(ref.id)
                    .accessibilityLabel(ref.accessibilityText)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $current)
        .scrollIndicators(.hidden)
        .background(Color.black)
        .ignoresSafeArea()
        .zoomDestination("image-\(current ?? images[0].id)")
        .toolbarVisibility(chrome ? .visible : .hidden, for: .navigationBar, .bottomBar)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .statusBarHidden(!chrome)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("\(index + 1) of \(images.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Copy", systemImage: "doc.on.doc") { copy() }
                Spacer()
                Button("Save", systemImage: "square.and.arrow.down") { save() }
                Spacer()
                ShareLink(item: SharedImage(ref: image, store: model.images),
                          preview: SharePreview(image.fileName, image: Image(uiImage: model.images.cached(image, thumbnail: true)
                                                                                       ?? model.images.cached(image, thumbnail: false) ?? UIImage())))
            }
        }
        .overlay(alignment: .bottom) {
            if chrome {
                Text([caption, image.name, Formatting.size(image.bytes)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 92)
                    .transition(.opacity)
            }
        }
        .overlay {
            if let hud {
                Text(hud)
                    .font(.headline)
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, Space.s)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(for: .seconds(1.2))
                        withAnimation(Motion.smooth(reduceMotion)) { self.hud = nil }
                    }
            }
        }
        .sensoryFeedback(.success, trigger: copies)
        .preferredColorScheme(.dark)
    }

    private var caption: String {
        switch image.source {
        case .read: "Read"
        case .pasted: "Pasted"
        case .mcp, .screenshot: "Screenshot"
        default: "Image"
        }
    }

    /// The original bytes under their own type, so a PNG stays a PNG.
    private func copy() {
        let ref = image
        Task {
            guard let data = await model.images.data(ref) else { return hud = "Couldn't load the image" }
            if let type = UTType(mimeType: ref.mime), UIImage(data: data) != nil {
                UIPasteboard.general.setData(data, forPasteboardType: type.identifier)
            } else {
                UIPasteboard.general.image = UIImage(data: data)
            }
            copies += 1
            hud = "Copied"
        }
    }

    private func save() {
        let ref = image
        Task {
            guard let data = await model.images.data(ref) else { return hud = "Couldn't load the image" }
            guard [.authorized, .limited].contains(await PHPhotoLibrary.requestAuthorization(for: .addOnly)) else {
                return hud = "Photos access is off"
            }
            do {
                try await Self.addToPhotos(data, name: ref.fileName)
                copies += 1
                hud = "Saved to Photos"
            } catch {
                hud = "Couldn't save it"
            }
        }
    }
}

extension ImageViewer {
    /// Photos runs the change block on its own queue, so it must not inherit the main actor.
    nonisolated static func addToPhotos(_ data: Data, name: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = name
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
        }
    }
}

/// One page: the thumbnail as it zooms open, the original swapped in once it's here.
private struct ViewerPage: View {
    let ref: ImageRef
    let onTap: () -> Void
    @Environment(AppModel.self) private var model
    @State private var full: UIImage?
    @State private var thumb: UIImage?

    var body: some View {
        ZoomableImage(image: full ?? model.images.cached(ref, thumbnail: false) ?? thumb ?? model.images.cached(ref, thumbnail: true), onTap: onTap)
            .overlay {
                if full == nil && thumb == nil && model.images.cached(ref, thumbnail: true) == nil { ProgressView().tint(.white) }
            }
            .task(id: ref.id) {
                if model.images.cached(ref, thumbnail: false) == nil { thumb = await model.images.image(ref, thumbnail: true) }
                full = await model.images.image(ref, thumbnail: false)
            }
    }
}

/// Share's item: the original file under its name, loaded when the sheet asks for it.
private struct SharedImage: Transferable {
    let ref: ImageRef
    let store: ImageStore

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { item in
            guard let data = await item.store.data(item.ref) else { throw CocoaError(.fileReadUnknown) }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(item.ref.id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(item.ref.fileName)
            try data.write(to: file, options: .atomic)
            return SentTransferredFile(file)
        }
    }
}

extension ImageRef {
    /// The name it came with, else the id and the extension its type implies.
    nonisolated var fileName: String {
        if let name, !name.isEmpty { return (name as NSString).lastPathComponent }
        return "\(id.prefix(8)).\(UTType(mimeType: mime)?.preferredFilenameExtension ?? "png")"
    }
}

/// The one UIKit piece: SwiftUI has no zooming scroll view (native zoom, bounce, deceleration).
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage?
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = true
        scroll.addSubview(view)
        context.coordinator.imageView = view

        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: double)
        scroll.addGestureRecognizer(single)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        context.coordinator.onTap = onTap
        DispatchQueue.main.async { context.coordinator.layout(in: scroll) }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        nonisolated deinit {}

        var imageView: UIImageView?
        var onTap: () -> Void

        init(onTap: @escaping () -> Void) { self.onTap = onTap }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func layout(in scroll: UIScrollView) {
            guard scroll.zoomScale == 1, let imageView else { return }
            imageView.frame = scroll.bounds
            scroll.contentSize = scroll.bounds.size
        }

        @objc func singleTap() { onTap() }

        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let scale: CGFloat = 2.5
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
