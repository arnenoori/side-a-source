import AppKit
import SwiftUI

/// The Sessions window around its browser: what the window knows that the conversations don't. Whether it is the key
/// window (so the Session menu applies), where the user has been (Back, Forward), and whether ⌘ is held for the
/// row numbers.
struct SessionsShell: View {
    @Bindable var model: SessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hold: Task<Void, Never>?
    @State private var monitor: Any?

    private var desk: SessionDesk { model.desk }

    var body: some View {
        SessionsBrowser(model: model)
            .background(KeyWindow { key, active in
                desk.windowKey = key
                desk.windowActive = active
            })
            .onChange(of: model.selectedID, initial: true) { _, id in
                desk.visited(id)
                if id != nil { desk.selectedLaunch = nil }
                // Arrowing through the list leaves the keyboard there; any other way of opening one is a wish to talk to it.
                if id != nil, id != desk.steppedTo { desk.composerFocus += 1 }
                // A request no message field was there to take must not hand the keyboard to the next one arrowed to.
                if id != nil, id == desk.steppedTo { desk.composerTaken = desk.composerFocus }
                if id != desk.steppedTo { desk.steppedTo = nil }
            }
            .task(id: WireStamp(model)) { if let id = model.selectedID { await model.loadWire(id) } }
            .task(id: model.openSession?.cwd) { await model.loadProjectActions(model.openSession?.cwd) }
            .task(id: model.error) {
                guard let shown = model.error else { return }
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled, model.error == shown { withAnimation(Ink.ease) { model.error = nil } }
            }
            .onAppear(perform: watchCommandKey)
            .onAppear(perform: model.restoreDrafts)
            .onAppear(perform: model.listenForSnoozes)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
                    Task { @MainActor in
                        guard !model.creating else { return }
                        desk.startFolder = url.path
                        model.creating = true
                    }
                }
                return true
            }
            .overlay(alignment: .top) {
                if desk.switching {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.001).onTapGesture { desk.switching = false }
                        SwitcherPanel(model: model).padding(.top, 90)
                    }
                    .transition(reduceMotion ? .opacity : Ink.rise(-6))
                }
            }
            .animation(reduceMotion ? nil : Ink.glide, value: desk.switching)
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                hold?.cancel()
                desk.numbered = false
                desk.windowKey = false
                desk.windowActive = false
            }
    }

    /// Row numbers show once ⌘ alone has been held a moment, so a quick ⌘3 never flashes them.
    private func watchCommandKey() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            let held = event.type == .flagsChanged && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command && desk.windowKey
            hold?.cancel()
            if held {
                hold = Task {
                    try? await Task.sleep(for: SessionsShell.hintDelay)
                    if !Task.isCancelled { withAnimation(reduceMotion ? nil : Ink.glide) { desk.numbered = true } }
                }
            } else if desk.numbered {
                withAnimation(reduceMotion ? nil : Ink.glide) { desk.numbered = false }
            }
            return event
        }
    }

    static let hintDelay: Duration = .milliseconds(200)
}

/// Reports whether the window this sits in has the keyboard itself, and whether it or a sheet or popover it presented does.
private struct KeyWindow: NSViewRepresentable {
    let changed: @MainActor (Bool, Bool) -> Void

    func makeNSView(context: Context) -> Watcher {
        let view = Watcher()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: Watcher, context: Context) { view.changed = changed }

    final class Watcher: NSView {
        var changed: (@MainActor (Bool, Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var last: [Bool] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard window != nil else { return report() }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            report()
        }

        private func report() {
            let key = NSApp.keyWindow
            let itself = window != nil && key === window
            let active = itself || (window != nil && key != nil && (key?.sheetParent === window || key?.parent === window))
            guard [itself, active] != last else { return }
            last = [itself, active]
            changed?(itself, active)
        }
    }
}

/// The number ⌘1…⌘9 opens, shown on a row while ⌘ is held.
struct NumberHint: ViewModifier {
    let model: SessionStore
    let id: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .trailing) {
            if model.desk.numbered, let id, let number = model.number(of: id) {
                Text("⌘\(number)")
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Ink.line))
                    .padding(.trailing, 6)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The line between the list and the conversation: drag it to resize the list, double-click to put it back.
struct SidebarDivider: View {
    let desk: SessionDesk
    @State private var start: Double?

    var body: some View {
        Rectangle().fill(Ink.line).frame(width: 1)
            .overlay {
                Color.clear.frame(width: 9).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let from = start ?? desk.sidebarWidth
                            start = from
                            desk.sidebarWidth = min(max(from + drag.translation.width, SessionPrefs.sidebarRange.lowerBound), SessionPrefs.sidebarRange.upperBound)
                        }
                        .onEnded { _ in start = nil })
                    .onTapGesture(count: 2) { withAnimation(Ink.glide) { desk.sidebarWidth = SessionPrefs.sidebarDefault } }
            }
            .accessibilityHidden(true)
    }
}
