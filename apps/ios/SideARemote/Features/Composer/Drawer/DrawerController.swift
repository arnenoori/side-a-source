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
    var camera: () -> Void
    var files: () -> Void
    /// The system picker, for the whole library.
    var picker: () -> Void
    /// Takes the clipboard's picture into the tray; false when there is none to take.
    var pasteImage: () -> Bool
    var options: () -> Void
}

/// One photo crossing from its cell to its tile in the tray.
struct DrawerFlight: Identifiable {
    let id: UUID
    let image: UIImage
    let from: CGRect
    var to: CGRect
}

/// The attachment drawer's state machine: closed, the menu, or the photo sheet. Every value the panel is drawn
/// from is a plain number that SwiftUI springs, so a tap or a drag during a move retargets the spring from
/// where it is instead of waiting for it, and both directions are one mechanism.
@MainActor @Observable
final class DrawerController {
    nonisolated deinit {}

    enum Mode { case closed, menu, photos }

    private(set) var mode: Mode = .closed
    /// 0 the circle that is the + button, 1 the menu at rest.
    var open: CGFloat = 0
    /// 0 menu-shaped, 1 the photo sheet.
    var morph: CGFloat = 0
    var menuOpacity: CGFloat = 1
    var gridOpacity: CGFloat = 0
    /// The soften-then-sharpen pulse over every change the panel makes.
    var blur: CGFloat = 0
    /// Reduce Motion: the panel fades instead of growing.
    var panelOpacity: CGFloat = 1
    var sheetTop: CGFloat = 0
    private(set) var closing = false

    var layout = DrawerLayout(window: .zero, safe: EdgeInsets(), plus: .zero, composer: .zero, menuSize: .zero, keyboardTop: nil)
    private(set) var rows = DrawerRows(camera: false, photos: false, files: false, paste: false)

    /// Photos picked in the grid, in the order they were tapped.
    private(set) var selected: [String] = []
    private(set) var flights: [DrawerFlight] = []
    /// 0 the photos are in their cells, 1 they are in the tray.
    var flight: CGFloat = 0
    /// Tray tiles the flying copies stand in for, held blank until the copies land.
    private(set) var landing: Set<UUID> = []
    private(set) var lifted: Set<String> = []

    /// Made on the first opening of the Photos sheet, so a composer that never opens it costs nothing.
    @ObservationIgnored private(set) lazy var photos = RecentPhotos()
    /// The picture each picked cell was showing, for the copy that flies out of it. Only picked photos are kept.
    @ObservationIgnored private var pickedImages: [String: UIImage] = [:]
    /// Set for a moment when the Paste row found nothing to take.
    private(set) var pasteFailed = false

    // Reported by the composer: the + button, the composer's row and the tray's tiles, in window coordinates.
    var plusFrame: CGRect = .zero { didSet { if plusFrame != oldValue { relayout() } } }
    var composerFrame: CGRect = .zero
    @ObservationIgnored var trayFrames: [UUID: CGRect] = [:]
    /// How the grid is laid out and scrolled, so a cell's place in the window is arithmetic, not a measurement per cell.
    @ObservationIgnored var gridSide: CGFloat = 0
    @ObservationIgnored var gridColumns = 3
    @ObservationIgnored var gridTopInset: CGFloat = 0
    @ObservationIgnored var gridScrolled: CGFloat = 0
    @ObservationIgnored weak var scene: UIWindowScene?
    @ObservationIgnored var windowSize: CGSize = .zero { didSet { if windowSize != oldValue { relayout() } } }
    @ObservationIgnored var safe = EdgeInsets() { didSet { if safe != oldValue { relayout() } } }
    @ObservationIgnored var container: CGRect? { didSet { if container != oldValue { relayout() } } }
    /// The docked keyboard's top edge in window coordinates, nil when it is down, floating or not over this window.
    /// The notification's frame is in screen coordinates; the window may not be the screen (split view, Stage Manager).
    private var keyboardTop: CGFloat? {
        guard let frame = KeyboardTracker.shared.frame, let scene,
              let space = (window ?? scene.keyWindow)?.coordinateSpace else { return nil }
        let converted = scene.screen.coordinateSpace.convert(frame, to: space)
        return converted.maxY >= space.bounds.height - 1 ? converted.minY : nil
    }
    @ObservationIgnored private var window: DrawerWindow?
    @ObservationIgnored private var hooks: DrawerHooks?
    @ObservationIgnored private var reduceMotion = false
    @ObservationIgnored private var after: (() -> Void)?
    @ObservationIgnored private var pulse: Task<Void, Never>?
    @ObservationIgnored private var lead: Task<Void, Never>?

    /// The window, the safe area, the keyboard or the + moved with the drawer open (rotation, the keyboard coming or
    /// going): the menu and sheet settle against the new geometry, staying at the detent they were at.
    private func relayout() {
        guard mode != .closed, !closing, windowSize.width > 0 else { return }
        // A rotation or a resized window: the drawer goes at once rather than being laid out again mid-turn, and the
        // + is where it was a moment ago for whoever wants it back.
        if layout.window != .zero, windowSize != layout.window { return closeNow() }
        guard !isDragging, !isFlying else { return }
        let wasLarge = isLarge
        let next = DrawerLayout(window: windowSize, safe: safe, plus: plusFrame, composer: composerFrame,
                                menuSize: DrawerMetrics.menuSize(rows: rows.count), keyboardTop: keyboardTop, container: container)
        guard next != layout else { return }
        withAnimation(arrive) {
            layout = next
            sheetTop = wasLarge ? next.largeTop : next.mediumTop
        }
    }

    var isOpen: Bool { mode != .closed }
    var isFlying: Bool { !flights.isEmpty }
    /// The real + button is the circle the panel starts from, so it steps aside for as long as the panel is up.
    var hidesPlus: Bool { mode != .closed || closing }

    // MARK: Springs

    /// The reference's panel spring: 400 ms, a touch of overshoot arriving, none leaving.
    private var arrive: Animation { reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.2) }
    private var leave: Animation { reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0) }
    private var fade: Animation { .easeOut(duration: reduceMotion ? 0.2 : 0.15) }

    // MARK: Open and close

    /// The + button's tap: opens the menu, or closes whatever is up.
    func toggle(rows: DrawerRows, hooks: DrawerHooks, reduceMotion: Bool) {
        if mode != .closed || lead != nil { return dismiss() }
        guard let scene, !closing else { return }
        self.reduceMotion = reduceMotion
        self.hooks = hooks
        self.rows = rows
        layout = DrawerLayout(window: windowSize, safe: safe, plus: plusFrame, composer: composerFrame,
                              menuSize: DrawerMetrics.menuSize(rows: rows.count), keyboardTop: keyboardTop, container: container)
        sheetTop = layout.mediumTop
        open = 0; morph = 0; menuOpacity = 1; gridOpacity = 0; blur = 0; flight = 0
        panelOpacity = reduceMotion ? 0 : 1
        selected = []; lifted = []; flights = []; landing = []; pickedImages = [:]; pasteFailed = false
        resetDrag()
        KeyboardTracker.shared.changed = { [weak self] in self?.relayout() }
        DrawerFeedback.light()
        mode = .menu
        window = DrawerWindow.show(in: scene, controller: self)
        // The panel mounts as the + button, one frame before it grows, so the circle is seen to open.
        lead = Task { @MainActor in
            await Task.yield()
            lead = nil
            guard mode == .menu, !closing else { return }
            withAnimation(arrive) {
                open = 1
                panelOpacity = 1
            }
        }
    }

    /// Menu → sheet.
    func showPhotos() {
        guard mode == .menu, !closing else { return }
        mode = .photos
        sheetTop = layout.mediumTop
        pulseBlur()
        withAnimation(arrive) { morph = 1 }
        withAnimation(fade) { menuOpacity = 0; gridOpacity = 1 }
        // Photos already allowed are listed at once, so the sheet arrives with its pictures; the system alert waits for the sheet.
        let delay = PhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite)).asksOnOpen ? 380 : 0
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard mode == .photos else { return }
            await photos.open { [weak self] asking in self?.window?.alpha = asking ? 0 : 1 }
        }
    }

    func backToMenu() {
        guard mode == .photos, !closing else { return }
        mode = .menu
        selected = []
        pulseBlur()
        photos.close()
        withAnimation(arrive) { morph = 0 }
        withAnimation(fade) { menuOpacity = 1; gridOpacity = 0 }
    }

    /// Collapses back into the + button. `then` runs once the panel is gone: a picker or the camera can only
    /// present over the app once the drawer's window has stopped covering it.
    func dismiss(then: (() -> Void)? = nil) {
        guard mode != .closed, !closing else { return }
        after = then
        closing = true
        lead?.cancel(); lead = nil
        selected = []
        pickedImages = [:]
        photos.close()
        generation += 1
        let mine = generation
        // A completion only fires if something animates. Closing before the panel started to open (the lead task
        // hasn't run) or with Reduce Motion while it is still transparent changes nothing, so close at once.
        let willMove = open != 0 || morph != 0 || (reduceMotion && panelOpacity != 0)
        guard willMove else { return finish() }
        withAnimation(leave, completionCriteria: .logicallyComplete) {
            open = 0
            morph = 0
            if reduceMotion { panelOpacity = 0 }
        } completion: { [weak self] in
            guard let self, self.generation == mine else { return }
            self.finish()
        }
        withAnimation(fade) { menuOpacity = 1; gridOpacity = 0 }
        backstop(mine, after: .milliseconds(700))
    }

    /// Belt and braces for a completion that never comes (a spring retargeted away, a window that came up while the
    /// app was busy). It can't close a newer opening: every close takes a new generation, a finished close
    /// clears `closing`, and the timer acts only on the generation that started it while that close is still going.
    private func backstop(_ mine: Int, after delay: Duration) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.generation == mine, self.closing else { return }
            self.finish()
        }
    }

    /// Closes without animating, for a window about to change shape under it, a screen leaving, or the app going away.
    func abort() {
        guard mode != .closed else { return }
        generation += 1
        lead?.cancel(); lead = nil
        photos.close()
        closing = true
        finish()
    }

    private func closeNow() { abort() }

    private func finish() {
        guard closing else { return }
        generation += 1
        window?.hide()
        window = nil
        KeyboardTracker.shared.changed = nil
        mode = .closed
        closing = false
        open = 0; morph = 0; menuOpacity = 1; gridOpacity = 0; flight = 0; panelOpacity = 1
        flights = []; landing = []; lifted = []; selected = []; pickedImages = [:]
        landings = 0
        resetDrag()
        photos.reset()
        let run = after
        after = nil
        run?()
    }

    /// The pick of a row that leaves the drawer for something else.
    func leaveFor(_ action: @escaping (DrawerHooks) -> Void) {
        guard let hooks else { return }
        dismiss { action(hooks) }
    }

    // MARK: Photos

    func toggle(_ asset: PHAsset, image: UIImage?) {
        guard !isFlying, !closing, !isDragging else { return }
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

    /// The Paste row: reads the picture, and only closes with it in hand. Reading raises the system's Allow Paste
    /// question when the clipboard came from another app; if that is refused or the picture is gone, the drawer stays
    /// and the row says so.
    func pasteFromClipboard() {
        guard let hooks, mode == .menu, !closing else { return }
        guard hooks.pasteImage() else {
            DrawerFeedback.warning()
            pasteFailed = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1800))
                self?.pasteFailed = false
            }
            return
        }
        dismiss()
    }

    func order(of asset: PHAsset) -> Int { (selected.firstIndex(of: asset.localIdentifier) ?? -1) + 1 }

    /// Attach the picked photos: copies leave their cells for their tiles on one spring, the sheet goes back
    /// into the + underneath them, and the full-size photos load behind that.
    func confirm() {
        guard let hooks, !selected.isEmpty, !closing, !isFlying else { return }
        let picked = selected.compactMap { id in photos.assets.first { $0.localIdentifier == id } }
        DrawerFeedback.medium()
        var made: [DrawerFlight] = []
        var ids: [String] = []
        for asset in picked {
            let thumbnail = pickedImages[asset.localIdentifier] ?? UIImage()
            guard let id = hooks.reserve(thumbnail, { await RecentPhotos.data(for: asset) }) else { break }
            ids.append(asset.localIdentifier)
            let from = cellFrame(of: asset) ?? sheetCentre
            made.append(DrawerFlight(id: id, image: thumbnail, from: from, to: .zero))
            Task { @MainActor in hooks.supply(id, await RecentPhotos.data(for: asset)) }
        }
        guard !made.isEmpty else { return dismiss() }
        if reduceMotion { return dismiss() }
        landing = Set(made.map(\.id))
        lifted = Set(ids)
        generation += 1
        let mine = generation
        landings = 0
        // Animation completions can be skipped; the drawer must never stay up on that, so the clock lands it too.
        backstop(mine, after: .milliseconds(1600))
        selected = []
        pickedImages = [:]
        closing = true
        after = nil
        photos.close()
        withAnimation(leave, completionCriteria: .logicallyComplete) {
            open = 0
            morph = 0
        } completion: { [weak self] in self?.landed(mine) }
        withAnimation(fade) { gridOpacity = 0; menuOpacity = 1 }
        // The tiles are in the tray by the next layout; their frames are what the copies fly to.
        Task { @MainActor [weak self] in
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(16))
                if made.allSatisfy({ self?.trayFrames[$0.id] != nil }) { break }
            }
            guard let self, self.closing else { return }
            for index in made.indices { made[index].to = self.destination(for: made[index].id) }
            self.flights = made
            // One frame at 0 so the copies are seen to leave, then the spring.
            try? await Task.sleep(for: .milliseconds(16))
            guard self.closing else { return }
            withAnimation(.spring(duration: 0.4, bounce: 0), completionCriteria: .logicallyComplete) {
                self.flight = 1
            } completion: { [weak self] in self?.landed(mine) }
        }
    }

    /// Where an asset's cell is in the window right now (the camera tile takes the first slot), nil when scrolled out of view.
    private func cellFrame(of asset: PHAsset) -> CGRect? {
        guard let index = photos.assets.firstIndex(of: asset), gridSide > 0 else { return nil }
        let slot = index + 1
        let sheet = layout.sheet(top: sheetTop)
        let frame = CGRect(x: sheet.minX + CGFloat(slot % gridColumns) * gridSide,
                           y: sheet.minY + gridTopInset + CGFloat(slot / gridColumns) * gridSide - gridScrolled,
                           width: gridSide - 1.5, height: gridSide - 1.5)
        return frame.intersects(sheet) ? frame : nil
    }

    /// The animations a confirm waits for: the sheet collapsing and the photos landing. Both must finish before the drawer goes.
    private(set) var landings = 0
    private(set) var generation = 0
    func landed(_ mine: Int) {
        guard generation == mine, closing else { return }
        landings += 1
        guard landings >= 2 else { return }
        landings = 0
        finish()
    }

    private var sheetCentre: CGRect {
        let sheet = layout.sheet(top: sheetTop)
        return CGRect(x: sheet.midX - 40, y: sheet.midY - 40, width: 80, height: 80)
    }

    /// The tile's frame, kept inside the composer when the tray has scrolled it out of sight.
    private func destination(for id: UUID) -> CGRect {
        let tile = trayFrames[id] ?? CGRect(x: composerFrame.minX, y: composerFrame.minY - 72, width: 64, height: 64)
        guard composerFrame.width > 0 else { return tile }
        var frame = tile
        frame.origin.x = min(max(frame.minX, composerFrame.minX), composerFrame.maxX - frame.width)
        return frame
    }

    // MARK: Sheet drag

    func settle(velocity: CGFloat) {
        guard mode == .photos else { return }
        guard let rest = layout.settle(top: sheetTop, velocity: velocity) else { return dismiss() }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.1)) { sheetTop = rest }
        DrawerFeedback.selection()
    }

    /// True while the sheet is being dragged and for a beat after, so a drag that began on a photo doesn't select it.
    private(set) var isDragging = false
    @ObservationIgnored private var dragEnd: Task<Void, Never>?

    /// The drag is over, ended or cancelled (a call banner, Control Center): the beat passes, then taps count again
    /// and a layout that waited for the drag is brought up to date.
    func endDrag() {
        dragEnd?.cancel()
        dragEnd = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            isDragging = false
            relayout()
        }
    }

    private func resetDrag() {
        dragEnd?.cancel()
        dragEnd = nil
        isDragging = false
    }

    func moveSheet(to top: CGFloat) {
        dragEnd?.cancel()
        isDragging = true
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { sheetTop = layout.rubberBanded(top) }
    }

    var isLarge: Bool { sheetTop <= layout.largeTop + 1 }

    func toggleDetent() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.1)) {
            sheetTop = isLarge ? layout.mediumTop : layout.largeTop
        }
    }

    private func pulseBlur() {
        guard !reduceMotion else { return }
        pulse?.cancel()
        withAnimation(.easeOut(duration: 0.06)) { blur = 1 }
        pulse = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.16)) { blur = 0 }
        }
    }

    // MARK: Limited library

    func widenLibrary() {
        guard let controller = window?.rootViewController else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        dismiss { UIApplication.shared.open(url) }
    }
}

/// Real haptics, prepared at the moment they are used.
@MainActor enum DrawerFeedback {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

/// The keyboard's frame in screen coordinates, kept for as long as the app runs. One set of observers for the
/// whole app, made the first time anything asks, and the drawer reads it when it opens instead of listening itself.
/// It listens for the keyboard hiding by name rather than judging an end frame against the screen's height,
/// which is the old orientation's during a rotation.
@MainActor
final class KeyboardTracker {
    static let shared = KeyboardTracker()
    nonisolated deinit {}

    private(set) var frame: CGRect?
    /// Whoever wants to know when it moves: the open drawer.
    var changed: (() -> Void)?
    private var hiding = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] note in
            let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            MainActor.assumeIsolated { self?.hiding = false; self?.set(end) }
        }
        center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            MainActor.assumeIsolated { if self?.hiding == false { self?.set(end) } }
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hiding = true; self?.set(nil) }
        }
    }

    /// Makes the tracker before the first keyboard, so none is missed.
    static func start() { _ = shared }

    private func set(_ new: CGRect?) {
        frame = new
        changed?()
    }
}
