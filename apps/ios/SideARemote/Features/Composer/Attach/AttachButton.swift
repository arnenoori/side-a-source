import SideAProtocol
import SideARemoteKit
import SwiftUI
import UIKit

enum AttachAction: Hashable {
    case camera, photos, files, paste, sessionFile, screen, options

    var title: String {
        switch self {
        case .camera: "Camera"
        case .photos: "Photos"
        case .files: "Files"
        case .paste: "Paste Photo"
        case .sessionFile: "File from This Session"
        case .screen: "Mac's Screen"
        case .options: "Commands"
        }
    }

    var symbol: String {
        switch self {
        case .camera: "camera"
        case .photos: "photo.on.rectangle"
        case .files: "folder"
        case .paste: "doc.on.clipboard"
        case .sessionFile: "at"
        case .screen: "display"
        case .options: "command"
        }
    }
}

/// SwiftUI's `Menu` can't be the control: with `primaryAction` a tap runs the action and a hold opens the menu, the
/// opposite of what this needs, and without it the menu takes the hold as well and keeps the finger for its own rows.
/// So the + owns one drag gesture that tells a tap from a hold itself, and the menu is a popover anchored to it.
struct AttachButton: View {
    let surface: AttachSurface
    let key: SessionKey?
    let tools: MacTools
    var diameter: CGFloat = 48
    var glyph: CGFloat = 19
    var label = "Add"
    var bare = false
    var onSessionFile: (() -> Void)?
    var offersScreen = false
    var hosted: String?
    var onOptions: (() -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.attachHeld) private var sheetHeld
    @State private var showsMenu = false
    @State private var sections: [[AttachAction]] = []
    /// Run once the menu has gone, so a picker or the drawer isn't asked up while the popover is still leaving.
    @State private var pending: AttachAction?
    @State private var press = AttachPress.idle
    @State private var holding: Task<Void, Never>?
    @State private var screen: ScreenModel?
    @GestureState private var touching = false

    private static let holdAfter = Duration.milliseconds(350)

    var body: some View {
        let open = surface.drawer.isOpen || surface.strip.isShown
        Image(systemName: "plus")
            .font(.system(size: glyph, weight: .medium))
            .rotationEffect(.degrees(open ? 45 : 0))
            .animation(Motion.snappy(reduceMotion), value: open)
            .frame(width: diameter, height: diameter)
            .pressedBacking(isEnabled && (touching || showsMenu || surface.strip.isShown), in: Circle().inset(by: 4))
            .contentShape(.circle)
            .hoverEffect(.highlight)
            .highPriorityGesture(pressGesture)
            .onChange(of: touching) { _, touching in if !touching { touchLost() } }
            .onChange(of: surface.strip.holdsTouch, initial: true) { _, holds in sheetHeld?.wrappedValue = holds }
            .onDisappear {
                surface.strip.pressing = false
                sheetHeld?.wrappedValue = false
            }
            .popover(isPresented: $showsMenu, arrowEdge: .bottom) { menu }
            .glassEffect(bare ? .identity : .regular.interactive(), in: .circle)
            .fullScreenCover(item: $screen) { screen in
                ScreenScreen(screen: screen).environment(model)
            }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(surface.drawer.isOpen ? "Show keyboard" : surface.strip.isShown ? "Close recent photos" : label)
            .accessibilityHint(open ? "" : "Photos, files and more")
            .accessibilityAction { if isEnabled { tap() } }
            .accessibilityAction(named: "Recent Photos") {
                guard isEnabled, !surface.strip.isShown else { return }
                Task { await hold(fingerDown: false) }
            }
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($touching) { _, touching, _ in touching = true }
            .onChanged(changed)
            .onEnded(ended)
    }

    private func changed(_ value: DragGesture.Value) {
        guard isEnabled else { return }
        pressed(.moved(start: value.startLocation, to: value.location), at: value.location)
    }

    private func ended(_ value: DragGesture.Value) {
        pressed(.lifted, at: value.location)
    }

    /// The system took the touch without an end (an alert went up, a call came in). Looked at a moment later, since
    /// a touch that really ended has had `ended` by then.
    private func touchLost() {
        Task { @MainActor in pressed(.lost, at: .zero) }
    }

    private func pressed(_ event: AttachPress.Event, at point: CGPoint) {
        let (next, effects) = press.next(event)
        press = next
        for effect in effects {
            switch effect {
            case .pressBegins:
                surface.strip.pressing = true
                surface.strip.prepare()
                holding?.cancel()
                holding = Task { @MainActor in
                    try? await Task.sleep(for: Self.holdAfter)
                    guard !Task.isCancelled, case .down = press else { return }
                    pressed(.heldLong, at: point)
                }
            case .cancelHold: holding?.cancel()
            case .showStrip: Task { await hold(fingerDown: true) }
            case .track(let to): surface.strip.track(to)
            case .tap: if isEnabled { tap() }
            case .release: if isEnabled { surface.strip.release(at: point) }
            case .stopTracking: surface.strip.cancelTracking()
            case .pressEnds: surface.strip.pressing = false
            }
        }
    }

    private func tap() {
        if surface.drawer.isOpen { return surface.drawer.showKeyboard() }
        if surface.strip.isShown || surface.strip.closedJustNow { return surface.strip.close() }
        openMenu()
    }

    private func hold(fingerDown: Bool) async {
        if surface.drawer.isOpen {
            pressed(.gaveUp, at: .zero)
            return surface.drawer.showKeyboard()
        }
        guard surface.room(key, tools: tools) > 0 else {
            pressed(.gaveUp, at: .zero)
            return openMenu()
        }
        surface.strip.onPick = { [surface, key, tools] asset, image in surface.attach(asset, thumbnail: image, key: key, tools: tools) }
        if await !surface.strip.show(held: fingerDown, window: surface.drawer.window) {
            if press == .held { pressed(.gaveUp, at: .zero) }
            openMenu()
        }
    }

    private func openMenu() {
        var attach: [AttachAction] = []
        if surface.room(key, tools: tools) > 0 {
            if surface.drawer.camera.hasCamera { attach.append(.camera) }
            attach += [.photos, .files]
            if UIPasteboard.general.hasImages { attach.append(.paste) }
        }
        var more: [AttachAction] = []
        if onSessionFile != nil, tools.can(.files) { more.append(.sessionFile) }
        if offersScreen, tools.can(.screen) { more.append(.screen) }
        if onOptions != nil { more.append(.options) }
        sections = [attach, more].filter { !$0.isEmpty }
        if !sections.isEmpty { showsMenu = true }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index > 0 { Divider().padding(.vertical, Space.xxs) }
                ForEach(section, id: \.self) { action in
                    Button { choose(action) } label: { MenuRow(action: action, host: model.mac.kind) }
                        .buttonStyle(MenuRowStyle())
                }
            }
        }
        .padding(.vertical, 6)
        .frame(minWidth: 240, alignment: .leading)
        .fixedSize()
        .presentationCompactAdaptation(.popover)
        .onDisappear {
            guard let action = pending else { return }
            pending = nil
            perform(action)
        }
    }

    private func choose(_ action: AttachAction) {
        pending = action
        showsMenu = false
    }

    private func perform(_ action: AttachAction) {
        switch action {
        case .camera: surface.openCamera(key: key, tools: tools, reduceMotion: reduceMotion)
        case .photos: surface.open(key: key, tools: tools, reduceMotion: reduceMotion, photosOnly: true)
        case .files: surface.showsFiles = true
        case .paste: if !surface.pasteImage(key: key, tools: tools) { DrawerFeedback.warning() }
        case .sessionFile: onSessionFile?()
        case .screen: Task { screen = await tools.screen(hosted: hosted) }
        case .options: onOptions?()
        }
    }
}

extension EnvironmentValues {
    @Entry var attachHeld: Binding<Bool>?
}

private struct MenuRow: View {
    let action: AttachAction
    let host: HostOS
    @ScaledMetric(relativeTo: .body) private var icon: CGFloat = 24

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: action.symbol)
                .frame(width: icon)
            Text(action == .screen ? "\(host.titleNoun)'s Screen" : action.title)
            Spacer(minLength: 0)
        }
        .font(.body)
        .padding(.horizontal, Space.m)
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed { Color(.tertiarySystemFill) }
            }
    }
}
