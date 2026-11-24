import SideAProtocol
import SideARemoteShared
import SwiftUI
import UIKit

struct ScreenScreen: View {
    @State private var screen: ScreenModel
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chrome = true
    @State private var keyboard = false
    @State private var modifiers = ScreenModifiers()

    init(screen: ScreenModel) {
        _screen = State(initialValue: screen)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            ScreenHost(screen: screen, keyboard: $keyboard, modifiers: modifiers) {
                withAnimation(Motion.smooth(reduceMotion)) { chrome.toggle() }
            }
            .ignoresSafeArea()
            .opacity(screen.phase == .live ? 1 : 0.35)
            if chrome || screen.phase != .live { topBar.transition(.opacity) }
        }
        .overlay { if case .stopped(let stop) = screen.phase { stopped(stop) } }
        .animation(Motion.smooth(reduceMotion), value: screen.phase)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .sensoryFeedback(.start, trigger: screen.phase == .live) { _, live in live }
        .onAppear { screen.start() }
        .onDisappear {
            // Leaving the foreground ends it below; a disappear while the app isn't active is the system moving things about.
            if scenePhase == .active { screen.stop() }
            UIApplication.shared.isIdleTimerDisabled = false
        }
        // Auto-Lock would end the stream long before the Mac's display sleeps.
        .onChange(of: screen.phase == .live, initial: true) { _, live in UIApplication.shared.isIdleTimerDisabled = live }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { screen.stop() } else if phase == .active { screen.start() }
        }
        .onChange(of: screen.controlling) { _, controlling in if !controlling { keyboard = false } }
    }

    private var topBar: some View {
        VStack(spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                Spacer(minLength: 0)
                targets
                Button {
                    screen.setControl(screen.mode != .control)
                } label: {
                    Image(systemName: screen.mode == .control ? "cursorarrow.click.2" : "cursorarrow.click")
                        .foregroundStyle(screen.mode == .control ? Color.black : Color.white)
                        .frame(width: 22, height: 22)
                        .background { if screen.mode == .control { Circle().fill(.white).padding(-6) } }
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Control")
                .accessibilityValue(screen.mode == .control ? "On" : "Off")
                .accessibilityAddTraits(.isToggle)
                .disabled(screen.ready == nil && screen.mode == .view)
                if screen.controlling {
                    Button("Keyboard", systemImage: "keyboard") { keyboard.toggle() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                }
            }
            if let status { statusLine(status) }
        }
        .foregroundStyle(.white)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .padding(.horizontal, Space.m)
        .padding(.top, Space.xs)
    }

    @ViewBuilder private var targets: some View {
        if let ready = screen.ready, ready.displays.count + ready.windows.count > 1 {
            Menu {
                Section("Displays") {
                    ForEach(ready.displays, id: \.id) { display in
                        Button(display.name, systemImage: shown(.display(display.id)) ? "checkmark" : "display") { screen.show(.display(display.id)) }
                    }
                }
                if !ready.windows.isEmpty {
                    Section("Windows") {
                        ForEach(ready.windows, id: \.id) { window in
                            Button(window.title.map { "\(window.app) · \($0)" } ?? window.app, systemImage: shown(.window(window.id)) ? "checkmark" : "macwindow") {
                                screen.show(.window(window.id))
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "rectangle.on.rectangle")
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Show")
        }
    }

    private func shown(_ target: ScreenTarget) -> Bool { screen.started?.target == target }

    private var status: String? {
        switch screen.phase {
        case .connecting: return "Connecting to \(model.mac.name)…"
        case .reconnecting: return screen.unreachable ? "Can't reach \(model.mac.name). Trying again…" : "Reconnecting…"
        case .stopped: return nil
        case .live:
            var parts = ["\(Int(screen.fps)) fps"]
            if let rtt = screen.rtt { parts.append("\(Int(rtt.rounded())) ms") }
            parts.append(route)
            if screen.quality?.reduced == true { parts.append(screen.ready?.route == .relay ? "Reduced quality over relay" : "Reduced quality") }
            if screen.mode == .control, let reason = screen.control.reason { parts.append(Self.why(reason, mac: model.mac.name, kind: screen.kind)) }
            return parts.joined(separator: " · ")
        }
    }

    private var route: String {
        if screen.ready?.route == .relay { return MacConnection.Route.relay.title }
        if let route = model.mac.route, route != .relay { return route.title }
        return "Direct"
    }

    static func why(_ reason: ScreenControlReason, mac: String, kind: HostOS = .macos) -> String {
        switch reason {
        case .off: "Control is off on \(mac)"
        case .accessibility: kind.isMac ? "Allow Side A in Accessibility on \(mac) to click" : "Side A can't click on \(mac)"
        case .locked: "\(mac) is locked"
        case .focus: "Not typed: this window isn't in front on \(mac)"
        default: "Watching only"
        }
    }

    private func statusLine(_ text: String) -> some View {
        HStack(spacing: Space.xs) {
            if screen.phase != .live { ProgressView().controlSize(.small).tint(.white) }
            Text(text).font(.caption.monospacedDigit()).lineLimit(2).contentTransition(.opacity)
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func stopped(_ stop: ScreenModel.Stop) -> some View {
        let (title, symbol, detail, action) = Self.describe(stop, mac: model.mac.name, kind: screen.kind)
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        } actions: {
            if let action { Button(action) { screen.retry() }.buttonStyle(.glassProminent) }
            Button("Close") { dismiss() }.buttonStyle(.glass)
        }
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.85))
    }

    static func describe(_ stop: ScreenModel.Stop, mac: String, kind: HostOS = .macos) -> (String, String, String, String?) {
        switch stop {
        case .off(let message): ("Screen Is Off", "display", message, "Try Again")
        case .permission(let message): (kind.isMac ? "Screen Recording Not Allowed" : "Screen Capture Not Allowed", "lock.display", message, "Try Again")
        case .replaced: ("Watching Elsewhere", "rectangle.on.rectangle.slash", "Another device started watching \(mac).", "Watch Here")
        case .ended(let message): ("Screen Sharing Ended", "display", message, "Watch Again")
        case .declined: ("Face ID Needed", "faceid", "Seeing \(mac)'s screen takes Face ID each time.", "Try Again")
        case .pairAgain: ("Pair Again", "iphone.gen3.badge.exclamationmark", "Pair this \(ThisDevice.kind) with \(mac) again to see its screen.", nil)
        case .update: ("Update Side A", "arrow.down.circle", "Update Side A on \(mac) and on this \(ThisDevice.kind) to see the screen.", nil)
        case .failed(let message): ("Couldn't Show the Screen", "exclamationmark.triangle", message, "Try Again")
        }
    }
}

private struct ScreenHost: UIViewRepresentable {
    let screen: ScreenModel
    @Binding var keyboard: Bool
    let modifiers: ScreenModifiers
    let toggleChrome: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ScreenCanvas {
        let canvas = ScreenCanvas(frame: .zero)
        let catcher = ScreenKeyCatcher(frame: .zero)
        catcher.modifiers = modifiers
        canvas.addSubview(catcher)
        let coordinator = context.coordinator
        coordinator.catcher = catcher
        let bar = UIHostingController(rootView: ScreenKeyBar(modifiers: modifiers, press: { [weak screen] in screen?.send(.key($0)) },
                                                             hide: { [weak catcher] in catcher?.resignFirstResponder() },
                                                             kind: screen.kind))
        bar.view.backgroundColor = .clear
        bar.view.frame = CGRect(x: 0, y: 0, width: 0, height: 52)
        bar.view.autoresizingMask = [.flexibleWidth]
        bar.sizingOptions = []
        catcher.accessory = bar.view
        coordinator.bar = bar
        catcher.pressed = { [weak screen] in screen?.send(.key($0)) }
        catcher.typed = { [weak screen] in screen?.type($0) }
        let decoder = coordinator.decoder
        screen.frames = { [weak canvas, weak screen] frame in
            guard let canvas else { return }
            if case .config(_, let width, let height, _) = frame { canvas.videoSize = CGSize(width: width, height: height) }
            if !decoder.show(frame, on: canvas.video.display) { screen?.needKeyframe() }
        }
        let toggleChrome = toggleChrome
        canvas.tapped = { [weak screen] point in
            guard let screen, screen.controlling else { return toggleChrome() }
            screen.send(.pointer(ScreenPointer(kind: .click, x: point.x, y: point.y)))
        }
        canvas.held = { [weak screen] point in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            screen?.send(.pointer(ScreenPointer(kind: .rightClick, x: point.x, y: point.y)))
        }
        canvas.scrolled = { [weak screen] point, delta in
            screen?.send(.scroll(ScreenScroll(x: point.x, y: point.y, dx: delta.dx, dy: delta.dy)))
        }
        return canvas
    }

    func updateUIView(_ canvas: ScreenCanvas, context: Context) {
        canvas.controlling = screen.controlling
        guard let catcher = context.coordinator.catcher else { return }
        if keyboard, screen.controlling, !catcher.isFirstResponder { catcher.becomeFirstResponder() }
        if !keyboard || !screen.controlling, catcher.isFirstResponder { catcher.resignFirstResponder() }
    }

    static func dismantleUIView(_ canvas: ScreenCanvas, coordinator: Coordinator) {
        coordinator.catcher?.resignFirstResponder()
    }

    @MainActor
    final class Coordinator {
        nonisolated deinit {}
        let decoder = ScreenDecoder()
        weak var catcher: ScreenKeyCatcher?
        var bar: UIHostingController<ScreenKeyBar>?
    }
}
