import Observation
import Photos
import SwiftUI
import UIKit

/// What the drawer needs from the composer that opened it, so the drawer knows nothing of sessions.
struct DrawerHooks {
    /// How many more photos the tray takes.
    var room: () -> Int
    /// A tile for a photo still being fetched, with how to fetch it again; nil when the tray is full.
    var reserve: (UIImage, @escaping @MainActor () async -> Data?) -> UUID?
    var supply: (UUID, Data?) -> Void
    var files: () -> Void
    /// The system picker, for the whole library.
    var picker: () -> Void
    /// Takes the clipboard's picture into the tray; false when there is none to take.
    var pasteImage: () -> Bool
    var options: () -> Void
}

/// The text field the drawer sits under: its focus and its keyboard are what the panel replaces.
@MainActor
final class FieldHandle {
    nonisolated deinit {}
    weak var view: UITextView?
    func focus() { _ = view?.becomeFirstResponder() }
    func resign() { _ = view?.resignFirstResponder() }
}

/// The attachment drawer's state. The panel is the keyboard's replacement: while it is open the field's input view is
/// the panel, at the height of the keyboard it took the place of, and the composer rides it exactly as it rides the
/// keyboard. Where there is no keyboard area to take (an iPad with a hardware keyboard) it is a popover from the +.
@MainActor @Observable
final class AttachDrawer {
    nonisolated deinit {}

    init(camera: CameraModel = CameraModel()) { self.camera = camera }

    private(set) var isOpen = false
    private(set) var presentation: PanelPresentation = .keyboardArea
    /// The panel's height in the keyboard's place: the keyboard's own at rest, taller when pulled up to the grid.
    private(set) var height: CGFloat = 0
    private(set) var detents = PanelDetents(base: 0, window: 0, safeTop: 0)
    /// Counts openings, so the panel's VoiceOver focus moves in each time.
    private(set) var openings = 0
    /// Set for the animation a height change takes; false while a finger is dragging it.
    private(set) var animatesHeight = false
    private(set) var rows = DrawerRows(camera: false, photos: false, files: false, paste: false)

    /// Photos picked, in the order they were tapped.
    private(set) var selected: [String] = []
    private(set) var pasteFailed = false
    private(set) var isDragging = false
    /// Where the camera tile sits in the panel, which is what the viewfinder grows from and shrinks back to.
    var tileRect = CGRect.zero

    @ObservationIgnored let camera: CameraModel
    /// Made on the first opening, so a composer that never opens the drawer costs nothing.
    @ObservationIgnored private(set) lazy var photos = RecentPhotos()
    @ObservationIgnored private var pickedImages: [String: UIImage] = [:]
    @ObservationIgnored let field = FieldHandle()
    @ObservationIgnored weak var window: UIWindow?
    @ObservationIgnored private(set) var hooks: DrawerHooks?
    @ObservationIgnored private var reduceMotion = false
    @ObservationIgnored private var dragStart: CGFloat = 0
    /// How far the grid has scrolled, so a drag down from its top takes the panel with it.
    @ObservationIgnored var gridScrolled: CGFloat = 0
    /// Applies a height to the field's input view; set by the field while the panel is its keyboard.
    @ObservationIgnored var heightSink: ((CGFloat, Bool) -> Void)?
    /// Where a drag may start, measured from the panel's top; nil is anywhere. A short list of actions scrolls at the
    /// largest text sizes, and a drag there is the list's.
    @ObservationIgnored var dragRegion: CGFloat?

    var isLarge: Bool { height > detents.base + (detents.large - detents.base) * 0.5 }
    /// 0 at the keyboard's height, 1 fully open.
    var progress: CGFloat {
        let span = detents.large - detents.base
        return span > 0 ? min(max((height - detents.base) / span, 0), 1) : 0
    }
    /// The panel is in the keyboard's place (as opposed to a popover).
    var takesKeyboard: Bool { isOpen && presentation == .keyboardArea }
    var showsPopover: Bool { isOpen && presentation == .popover }

    // MARK: Open and close

    /// The + button's tap: opens the panel, or swaps back to the keyboard.
    func toggle(rows: DrawerRows, hooks: DrawerHooks, reduceMotion: Bool) {
        if isOpen { return showKeyboard() }
        self.reduceMotion = reduceMotion
        self.hooks = hooks
        self.rows = rows
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
        DrawerFeedback.light()
        camera.start()
        Task { @MainActor [weak self] in await self?.photos.open() }
    }

    /// Escape from a hardware keyboard: the viewfinder shrinks back first, then the panel gives way to the keyboard.
    func escape() {
        if camera.shooting { closeCamera() } else { showKeyboard() }
    }

    /// Back to the keyboard, in the panel's place: the field keeps its focus, so the keyboard is what is there.
    func showKeyboard() {
        guard isOpen else { return }
        let wasKeyboard = presentation == .keyboardArea
        finish()
        if wasKeyboard { field.focus() }
    }

    /// The field lost the keyboard on its own (swiped away, or another field took it): the panel goes with it.
    func fieldEnded() {
        guard isOpen, presentation == .keyboardArea else { return }
        finish()
    }

    /// Closes and lets go of the keyboard too, for a picker or the camera about to cover the app.
    func close(then: (() -> Void)? = nil) {
        guard isOpen else { return then?() ?? () }
        // The keyboard goes first: closing the panel on its own would hand the field's keyboard back for a moment.
        field.resign()
        finish()
        then?()
    }

    /// Closes at once, for a screen leaving, the app going away or the window changing shape.
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

    /// The pick of a row that leaves the drawer for something else.
    func leaveFor(_ action: @escaping (DrawerHooks) -> Void) {
        guard let hooks else { return }
        close { action(hooks) }
    }

    // MARK: Photos

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

    /// Attach the picked photos: their tiles appear in the tray now, the full-size photos load behind them, and the
    /// keyboard comes back in the panel's place.
    func confirm() {
        guard let hooks, !selected.isEmpty else { return }
        let picked = selected.compactMap { id in photos.assets.first { $0.localIdentifier == id } }
        DrawerFeedback.medium()
        for asset in picked {
            let thumbnail = pickedImages[asset.localIdentifier] ?? UIImage()
            guard let id = hooks.reserve(thumbnail, { await RecentPhotos.data(for: asset) }) else { break }
            Task { @MainActor in hooks.supply(id, await RecentPhotos.data(for: asset)) }
        }
        showKeyboard()
    }

    // MARK: Viewfinder

    /// The tile's preview grows to fill the panel, which pulls up to the grid's height around it. The session keeps running,
    /// so nothing restarts and nothing flashes black.
    func openCamera() {
        guard isOpen, camera.isLive else { return DrawerFeedback.warning() }
        DrawerFeedback.light()
        camera.open()
        settle(to: detents.large)
    }

    /// The viewfinder shrinks back into the tile and the panel comes down to the keyboard's height, tile live again.
    func closeCamera() {
        guard camera.shooting else { return }
        camera.close()
        settle(to: detents.base)
    }

    /// Takes a photo into the tray, through the same reserved tile the library's photos use, and returns to the panel.
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

    /// A small picture of a photo for its tray tile, so the full-size one isn't held twice.
    nonisolated static func thumbnail(of data: Data) -> UIImage {
        guard let image = UIImage(data: data) else { return UIImage() }
        let longest = max(image.size.width, image.size.height)
        guard longest > 400 else { return image }
        let scale = 400 / longest
        return image.preparingThumbnail(of: CGSize(width: image.size.width * scale, height: image.size.height * scale)) ?? image
    }

    // MARK: Height

    private var spring: Animation { reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.1) }

    func toggleDetent() {
        settle(to: isLarge ? detents.base : detents.large)
    }

    private func settle(to target: CGFloat) {
        animatesHeight = true
        height = target
        heightSink?(target, true)
        DrawerFeedback.selection()
    }

    /// The finger is moving the panel: `translation` is how far down it has gone since the drag began.
    func drag(by translation: CGFloat) {
        if !isDragging { isDragging = true; dragStart = height }
        animatesHeight = false
        let next = detents.rubberBanded(dragStart - translation)
        // Below the keyboard's height it follows, but only a little: past that it is a dismissal, decided on release.
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

    // MARK: Limited library

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

/// Real haptics, prepared at the moment they are used.
@MainActor enum DrawerFeedback {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
