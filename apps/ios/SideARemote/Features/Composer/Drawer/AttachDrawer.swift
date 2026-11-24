import Observation
import Photos
import SwiftUI
import UIKit

struct DrawerHooks {
    var room: () -> Int
    var reserve: (UIImage, @escaping @MainActor () async -> Data?) -> UUID?
    var supply: (UUID, Data?) -> Void
    var files: () -> Void
    var picker: () -> Void
    var pasteImage: () -> Bool

    @MainActor func add(_ asset: PHAsset, thumbnail: UIImage) -> Bool {
        guard let id = reserve(thumbnail, { await RecentPhotos.data(for: asset) }) else { return false }
        Task { @MainActor in supply(id, await RecentPhotos.data(for: asset)) }
        return true
    }
}

@MainActor
final class FieldHandle {
    nonisolated deinit {}
    weak var view: UITextView?
    func focus() { _ = view?.becomeFirstResponder() }
    func resign() { _ = view?.resignFirstResponder() }
}

@MainActor @Observable
final class AttachDrawer {
    nonisolated deinit {}

    init(camera: CameraModel = CameraModel()) { self.camera = camera }

    private(set) var isOpen = false
    private(set) var presentation: PanelPresentation = .keyboardArea
    private(set) var height: CGFloat = 0
    private(set) var detents = PanelDetents(base: 0, window: 0, safeTop: 0)
    private(set) var openings = 0
    private(set) var animatesHeight = false
    private(set) var rows = DrawerRows(camera: false, photos: false, files: false, paste: false)
    private(set) var photosOnly = false

    private(set) var selected: [String] = []
    private(set) var pasteFailed = false
    private(set) var isDragging = false
    var tileRect = CGRect.zero

    @ObservationIgnored let camera: CameraModel
    @ObservationIgnored private(set) lazy var photos = RecentPhotos()
    @ObservationIgnored private var pickedImages: [String: UIImage] = [:]
    @ObservationIgnored let field = FieldHandle()
    @ObservationIgnored weak var window: UIWindow?
    @ObservationIgnored private(set) var hooks: DrawerHooks?
    @ObservationIgnored private var reduceMotion = false
    @ObservationIgnored private var dragStart: CGFloat = 0
    @ObservationIgnored var gridScrolled: CGFloat = 0
    @ObservationIgnored var heightSink: ((CGFloat, Bool) -> Void)?
    @ObservationIgnored var dragRegion: CGFloat?

    var isLarge: Bool { height > detents.base + (detents.large - detents.base) * 0.5 }
    var showsGrid: Bool { isLarge || (photosOnly && presentation == .keyboardArea) }
    var showsInlineGrid: Bool { isOpen && photosOnly && presentation == .keyboardArea }
    var progress: CGFloat {
        let span = detents.large - detents.base
        return span > 0 ? min(max((height - detents.base) / span, 0), 1) : 0
    }
    var takesKeyboard: Bool { isOpen && presentation == .keyboardArea }
    var showsPopover: Bool { isOpen && presentation == .popover }

    func toggle(rows: DrawerRows, hooks: DrawerHooks, reduceMotion: Bool, photosOnly: Bool = false) {
        if isOpen { return showKeyboard() }
        self.reduceMotion = reduceMotion
        self.hooks = hooks
        self.rows = rows
        self.photosOnly = photosOnly
        presentation = KeyboardMetrics.shared.presentation
        let size = window?.bounds.size ?? CGSize(width: 393, height: 852)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let base = KeyboardMetrics.shared.panelHeight(landscape: size.width > size.height, isPad: isPad)
        detents = PanelDetents(base: base, window: size.height, safeTop: window?.safeAreaInsets.top ?? 0)
        height = base
        animatesHeight = false
        selected = []
        pickedImages = [:]
        pasteFailed = false
        gridScrolled = 0
        openings += 1
        KeyboardMetrics.shared.panelIsShowing = presentation == .keyboardArea
        isOpen = true
        camera.start()
        Task { @MainActor [weak self] in await self?.photos.open() }
    }

    func escape() {
        if camera.shooting { closeCamera() } else { showKeyboard() }
    }

    func showKeyboard() {
        guard isOpen else { return }
        let wasKeyboard = presentation == .keyboardArea
        finish()
        if wasKeyboard { field.focus() }
    }

    func fieldEnded() {
        guard isOpen, presentation == .keyboardArea else { return }
        finish()
    }

    func close(then: (() -> Void)? = nil) {
        guard isOpen else { return then?() ?? () }
        // The keyboard goes first: closing the panel on its own would hand the field's keyboard back for a moment.
        field.resign()
        finish()
        then?()
    }

    func abort() {
        guard isOpen else { return }
        finish()
    }

    private func finish() {
        isOpen = false
        isDragging = false
        selected = []
        pickedImages = [:]
        KeyboardMetrics.shared.panelIsShowing = false
        camera.stop()
        photos.close()
        photos.reset()
    }

    func leaveFor(_ action: @escaping (DrawerHooks) -> Void) {
        guard let hooks else { return }
        close { action(hooks) }
    }

    func toggle(_ asset: PHAsset, image: UIImage?) {
        guard !isDragging else { return }
        let id = asset.localIdentifier
        if let index = selected.firstIndex(of: id) {
            selected.remove(at: index)
            pickedImages[id] = nil
            DrawerFeedback.selection()
        } else if selected.count < (hooks?.room() ?? 0) {
            selected.append(id)
            pickedImages[id] = image
            DrawerFeedback.selection()
        } else {
            DrawerFeedback.warning()
        }
    }

    func order(of asset: PHAsset) -> Int { (selected.firstIndex(of: asset.localIdentifier) ?? -1) + 1 }

    /// The Paste row: reads the picture, and only closes with it in hand. Reading raises the system's Allow Paste
    /// question when the clipboard came from another app; if that is refused or the picture is gone, the drawer stays
    /// and the row says so.
    func pasteFromClipboard() {
        guard let hooks, isOpen else { return }
        guard hooks.pasteImage() else {
            DrawerFeedback.warning()
            pasteFailed = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1800))
                self?.pasteFailed = false
            }
            return
        }
        showKeyboard()
    }

    func confirm() {
        guard let hooks, !selected.isEmpty else { return }
        let picked = selected.compactMap { id in photos.assets.first { $0.localIdentifier == id } }
        DrawerFeedback.medium()
        for asset in picked {
            guard hooks.add(asset, thumbnail: pickedImages[asset.localIdentifier] ?? UIImage()) else { break }
        }
        showKeyboard()
    }

    /// The tile's preview grows to fill the panel, which pulls up to the grid's height around it. The session keeps running,
    /// so nothing restarts and nothing flashes black.
    func openCamera() {
        guard isOpen, camera.isLive else { return DrawerFeedback.warning() }
        DrawerFeedback.light()
        camera.open()
        settle(to: detents.large)
    }

    func closeCamera() {
        guard camera.shooting else { return }
        camera.close()
        settle(to: detents.base)
    }

    func shutter() {
        guard camera.shooting, !camera.capturing, let hooks else { return }
        guard hooks.room() > 0 else { return DrawerFeedback.warning() }
        let angle = CameraAccess.previewAngle(for: window?.windowScene?.interfaceOrientation ?? .portrait)
        Task { @MainActor [weak self] in
            guard let self, let data = await camera.capture(angle: angle) else { return DrawerFeedback.warning() }
            DrawerFeedback.medium()
            if let id = hooks.reserve(Self.thumbnail(of: data), { data }) { hooks.supply(id, data) }
            closeCamera()
        }
    }

    nonisolated static func thumbnail(of data: Data) -> UIImage {
        guard let image = UIImage(data: data) else { return UIImage() }
        let longest = max(image.size.width, image.size.height)
        guard longest > 400 else { return image }
        let scale = 400 / longest
        return image.preparingThumbnail(of: CGSize(width: image.size.width * scale, height: image.size.height * scale)) ?? image
    }

    func toggleDetent() {
        settle(to: isLarge ? detents.base : detents.large)
    }

    private func settle(to target: CGFloat) {
        animatesHeight = true
        height = target
        heightSink?(target, true)
        DrawerFeedback.selection()
    }

    func drag(by translation: CGFloat) {
        if !isDragging { isDragging = true; dragStart = height }
        animatesHeight = false
        let next = detents.rubberBanded(dragStart - translation)
        height = max(next, detents.base - detents.dismissDistance * 1.5)
        heightSink?(height, false)
    }

    func endDrag(velocity: CGFloat) {
        guard isDragging else { return }
        isDragging = false
        switch detents.settle(height: height, velocity: velocity) {
        case .base: settle(to: detents.base)
        case .large: settle(to: detents.large)
        case .dismiss:
            height = detents.base
            heightSink?(detents.base, false)
            close()
        }
    }

    func widenLibrary() {
        guard let controller = Self.topController(in: window) else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        close { UIApplication.shared.open(url) }
    }

    private static func topController(in window: UIWindow?) -> UIViewController? {
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}

@MainActor enum DrawerFeedback {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
