import Observation
import PhotosUI
import SideAProtocol
import SwiftUI
import UniformTypeIdentifiers

/// Everything a screen needs to attach photos: the drawer, the system pickers it hands over to, the camera, and the
/// text field's paste hook. The session composer and the New Session sheet each own one and show the + and the tray
/// their own way; the photos go into the Mac's `ComposerAttachments` under whatever key the screen names (a session's
/// id, or a draft's before the session exists).
@MainActor @Observable
final class AttachSurface {
    nonisolated deinit {}

    let drawer = DrawerController()
    let paste = PasteBridge()
    /// What the paste hook and the drawer's Paste row read at the moment of pasting, not at the moment they were set up.
    let target = AttachTarget()
    var picks: [PhotosPickerItem] = []
    var showsPicker = false
    var showsFiles = false
    var takesPhoto = false

    /// Photos the tray takes, 0 when the Mac can't take uploads.
    func room(_ key: SessionKey?, tools: MacTools) -> Int {
        key.flatMap { tools.can(.uploads) ? tools.attachments.room($0) : nil } ?? 0
    }

    func add(_ images: [Data], room: Int) { for data in images.prefix(room) { target.add(data) } }

    /// Opens the drawer, or closes whatever is up. False when there is nothing to attach (a Mac that can't take uploads, a
    /// full tray, no window yet): the caller does what it did before the drawer. `options` is the menu's last row;
    /// nil leaves it out.
    @discardableResult
    func open(key: SessionKey?, tools: MacTools, reduceMotion: Bool, options: (() -> Void)?) -> Bool {
        guard let key else { return false }
        let room = room(key, tools: tools)
        let rows = DrawerRows.make(canUpload: tools.can(.uploads), room: room, hasCamera: CameraPicker.isAvailable,
                                   clipboardHasImage: UIPasteboard.general.hasImages, options: options != nil)
        guard rows.attaches, drawer.scene != nil else { return false }
        let attachments = tools.attachments
        let hooks = DrawerHooks(
            room: { attachments.room(key) },
            reserve: { attachments.reserve(preview: $0, in: key, refetch: $1) },
            supply: { attachments.supply($0, $1, in: key) },
            camera: { [self] in takesPhoto = true },
            files: { [self] in showsFiles = true },
            picker: { [self] in showsPicker = true },
            pasteImage: { [self] in
                guard let data = UIPasteboard.general.image?.jpegData(compressionQuality: 0.95) else { return false }
                add([data], room: attachments.room(key))
                return true
            },
            options: options ?? {})
        drawer.toggle(rows: rows, hooks: hooks, reduceMotion: reduceMotion)
        return true
    }
}

extension View {
    /// The presenters and hooks an `AttachSurface` needs from the screen it sits in: the pickers, the camera, the paste
    /// hook on `focused`'s field, and the drawer closed whenever the screen goes away, changes key or leaves the foreground.
    func attachments(_ surface: AttachSurface, key: SessionKey?, tools: MacTools, focused: FocusState<Bool>.Binding) -> some View {
        modifier(AttachPresenters(surface: surface, key: key, tools: tools, focused: focused))
    }
}

private struct AttachPresenters: ViewModifier {
    @Bindable var surface: AttachSurface
    let key: SessionKey?
    let tools: MacTools
    var focused: FocusState<Bool>.Binding
    @Environment(\.scenePhase) private var scenePhase

    private var room: Int { surface.room(key, tools: tools) }

    func body(content: Content) -> some View {
        content
            .background { SceneAnchor { scene, size, safe, container in
                surface.drawer.scene = scene
                surface.drawer.windowSize = size
                surface.drawer.safe = safe
                surface.drawer.container = container
            } }
            // The drawer's window never becomes key, so Escape from a hardware keyboard arrives here, focus or none.
            .background {
                if surface.drawer.isOpen {
                    Button("Close") { surface.drawer.dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            // Photos dragged in from another app on iPad go in as Files and Paste do.
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
            .fullScreenCover(isPresented: $surface.takesPhoto) {
                CameraPicker { data in surface.add([data], room: room) }
                    .ignoresSafeArea()
            }
            .onChange(of: key, initial: true) { _, key in
                let target = surface.target
                target.session = key
                target.attachments = tools.attachments
                target.canUpload = tools.can(.uploads)
                surface.paste.room = { [target] in target.room }
                surface.paste.onImage = { [target] data in target.add(data) }
            }
            // A different Mac has its own tray.
            .onChange(of: ObjectIdentifier(tools.attachments)) { surface.target.attachments = tools.attachments }
            .onChange(of: tools.can(.uploads)) { _, can in surface.target.canUpload = can }
            .onAppear { KeyboardTracker.start() }
            .onDisappear { surface.drawer.abort() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { surface.drawer.abort() } }
            .onChange(of: key) { surface.drawer.abort() }
            .onChange(of: focused.wrappedValue) { _, isFocused in
                guard isFocused else { return }
                // The field becomes first responder a little after focus says so; look for it for a moment.
                Task { @MainActor in
                    for _ in 0..<10 {
                        surface.paste.install()
                        if surface.paste.isInstalled { return }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
    }
}

/// Where a paste goes right now: the key the screen attaches under and the Mac's tray, kept current by the screen and
/// read when the paste happens.
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

/// Photos dropped from another app. A full tray (or a Mac that takes no uploads) doesn't light up under the drag; a
/// drop of more than fits takes what fits, and says so with the same warning the drawer gives.
struct PhotoDrop: DropDelegate {
    let room: Int
    let add: @MainActor (Data) -> Void

    /// How many of `count` dropped photos the tray takes.
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
