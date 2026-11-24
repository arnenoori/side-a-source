import Observation
import Photos
import PhotosUI
import SideAProtocol
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class AttachSurface {
    nonisolated deinit {}

    let drawer = AttachDrawer()
    let strip = RecentStrip()
    let target = AttachTarget()
    var picks: [PhotosPickerItem] = []
    var showsPicker = false
    var showsFiles = false

    func room(_ key: SessionKey?, tools: MacTools) -> Int {
        key.flatMap { tools.can(.uploads) ? tools.attachments.room($0) : nil } ?? 0
    }

    func add(_ images: [Data], room: Int) { for data in images.prefix(room) { target.add(data) } }

    @discardableResult
    func open(key: SessionKey?, tools: MacTools, reduceMotion: Bool, photosOnly: Bool = false) -> Bool {
        guard let key else { return false }
        let room = room(key, tools: tools)
        let rows = DrawerRows.make(canUpload: tools.can(.uploads), room: room, hasCamera: drawer.camera.hasCamera,
                                   clipboardHasImage: UIPasteboard.general.hasImages)
        guard rows.attaches else { return false }
        drawer.toggle(rows: rows, hooks: hooks(key: key, tools: tools), reduceMotion: reduceMotion, photosOnly: photosOnly)
        return true
    }

    func openCamera(key: SessionKey?, tools: MacTools, reduceMotion: Bool) {
        guard !drawer.isOpen, open(key: key, tools: tools, reduceMotion: reduceMotion, photosOnly: true) else { return }
        let drawer = drawer
        Task { @MainActor in
            if drawer.camera.access.asksOnTap { await drawer.camera.ask() }
            switch drawer.camera.access {
            case .authorized:
                try? await Task.sleep(for: .milliseconds(320))
                drawer.openCamera()
            case .denied: drawer.openSettings()
            default: DrawerFeedback.warning()
            }
        }
    }

    /// The + menu's Paste. Reading raises the system's Allow Paste question for another app's picture; false when that
    /// was refused or the picture is gone.
    func pasteImage(key: SessionKey?, tools: MacTools) -> Bool {
        guard let key else { return false }
        return pasteClipboard(into: tools.attachments, key: key)
    }

    func attach(_ asset: PHAsset, thumbnail: UIImage?, key: SessionKey?, tools: MacTools) {
        guard let key else { return }
        if !hooks(key: key, tools: tools).add(asset, thumbnail: thumbnail ?? UIImage()) { DrawerFeedback.warning() }
    }

    private func pasteClipboard(into attachments: ComposerAttachments, key: SessionKey) -> Bool {
        guard let data = UIPasteboard.general.image?.jpegData(compressionQuality: 0.95) else { return false }
        add([data], room: attachments.room(key))
        return true
    }

    private func hooks(key: SessionKey, tools: MacTools) -> DrawerHooks {
        let attachments = tools.attachments
        return DrawerHooks(
            room: { attachments.room(key) },
            reserve: { attachments.reserve(preview: $0, in: key, refetch: $1) },
            supply: { attachments.supply($0, $1, in: key) },
            files: { [self] in showsFiles = true },
            picker: { [self] in showsPicker = true },
            pasteImage: { [self] in pasteClipboard(into: attachments, key: key) })
    }
}

extension View {
    func attachments(_ surface: AttachSurface, key: SessionKey?, tools: MacTools) -> some View {
        modifier(AttachPresenters(surface: surface, key: key, tools: tools))
    }

    func attachPopover(_ surface: AttachSurface) -> some View {
        modifier(AttachPopover(drawer: surface.drawer))
    }
}

private struct AttachPresenters: ViewModifier {
    @Bindable var surface: AttachSurface
    let key: SessionKey?
    let tools: MacTools
    @Environment(\.scenePhase) private var scenePhase

    private var room: Int { surface.room(key, tools: tools) }

    func body(content: Content) -> some View {
        content
            .modifier(AttachPickers(surface: surface, key: key, tools: tools))
            .background { WindowReader { surface.drawer.window = $0 } }
            .background {
                if surface.drawer.isOpen {
                    Button("Close") { surface.drawer.escape() }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: key, initial: true) { _, key in
                let target = surface.target
                target.session = key
                target.attachments = tools.attachments
                target.canUpload = tools.can(.uploads)
            }
            .onChange(of: ObjectIdentifier(tools.attachments)) { surface.target.attachments = tools.attachments }
            .onChange(of: tools.can(.uploads)) { _, can in surface.target.canUpload = can }
            .onAppear { KeyboardMetrics.start() }
            .onDisappear { surface.drawer.abort(); surface.strip.close() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { surface.drawer.abort(); surface.strip.close() }
                // The camera may have been allowed or refused in Settings while the app was away.
                if phase == .active { surface.drawer.camera.refresh() }
            }
            .onChange(of: key) { surface.drawer.abort(); surface.strip.close() }
    }
}

private struct AttachPickers: ViewModifier {
    @Bindable var surface: AttachSurface
    let key: SessionKey?
    let tools: MacTools

    private var room: Int { surface.room(key, tools: tools) }

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.image], delegate: PhotoDrop(room: room) { [surface, key, tools] data in
                surface.add([data], room: surface.room(key, tools: tools))
            })
            .photosPicker(isPresented: $surface.showsPicker, selection: $surface.picks, maxSelectionCount: max(room, 1), matching: .images)
            .onChange(of: surface.picks) { _, picked in
                guard !picked.isEmpty else { return }
                surface.picks = []
                Task {
                    var loaded: [Data] = []
                    for item in picked { if let data = try? await item.loadTransferable(type: Data.self) { loaded.append(data) } }
                    surface.add(loaded, room: room)
                }
            }
            .fileImporter(isPresented: $surface.showsFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                surface.add(urls.prefix(room).compactMap { url in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try? Data(contentsOf: url)
                }, room: room)
            }
    }
}

private struct AttachPopover: ViewModifier {
    let drawer: AttachDrawer

    func body(content: Content) -> some View {
        content.popover(isPresented: Binding(get: { drawer.showsPopover }, set: { if !$0 { drawer.abort() } }), arrowEdge: .bottom) {
            AttachPanel(drawer: drawer, inPopover: true)
                .frame(width: 380, height: 420)
                .presentationCompactAdaptation(.popover)
        }
    }
}

@MainActor
final class AttachTarget {
    nonisolated deinit {}

    var session: SessionKey?
    var attachments: ComposerAttachments?
    var canUpload = false

    var room: Int {
        guard canUpload, let session, let attachments else { return 0 }
        return attachments.room(session)
    }

    func add(_ data: Data) {
        guard room > 0, let session, let attachments else { return }
        attachments.add(data, to: session)
    }
}

struct PhotoDrop: DropDelegate {
    let room: Int
    let add: @MainActor (Data) -> Void

    static func taken(_ count: Int, room: Int) -> Int { max(min(count, room), 0) }

    func validateDrop(info: DropInfo) -> Bool { room > 0 && info.hasItemsConforming(to: [.image]) }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: room > 0 ? .copy : .forbidden) }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.image])
        let taken = Self.taken(providers.count, room: room)
        guard taken > 0 else { return false }
        if taken < providers.count { DrawerFeedback.warning() }
        let add = add
        for provider in providers.prefix(taken) {
            _ = provider.loadTransferable(type: DroppedImage.self) { result in
                guard case .success(let image) = result else { return }
                Task { @MainActor in add(image.data) }
            }
        }
        return true
    }
}

struct WindowReader: UIViewRepresentable {
    let onChange: (UIWindow?) -> Void

    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.onChange = onChange
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Anchor, context: Context) { view.onChange = onChange }

    final class Anchor: UIView {
        var onChange: ((UIWindow?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); onChange?(window) }
    }
}
