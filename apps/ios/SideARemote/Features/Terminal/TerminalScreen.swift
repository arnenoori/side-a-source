import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftTerm
import SwiftUI
import UIKit

/// The terminal (section 4.9): full bleed and always dark, SwiftTerm on the hosted session's
/// `ws/term`, a glass key bar riding the keyboard, Chat and the session's name floating on top.
struct TerminalScreen: View {
    let name: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("terminal.fontSize") private var fontSize = 13.0
    @State private var terminal: TerminalModel
    @State private var chromeVisible = true
    @State private var hud: String?
    @State private var lastTyped = Date.distantPast
    /// Text the session asked to put on the clipboard, waiting for the user's answer.
    @State private var clipboardRequest: String?
    @State private var copied = 0
    @State private var attached = false

    init(name: String, model terminal: TerminalModel) {
        self.name = name
        _terminal = State(initialValue: terminal)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.terminalBackground.ignoresSafeArea()
            TerminalHost(terminal: terminal, fontSize: $fontSize, onTyped: typed, onPinch: showSize, onClipboard: clipboard)
                .ignoresSafeArea(.container, edges: .bottom)
                .padding(.top, 52)
                .opacity(terminal.phase == .attaching ? 0.4 : 1)
            topBar
            if let banner { bannerView(banner) }
        }
        .animation(Motion.smooth(reduceMotion), value: banner)
        .overlay {
            if let hud {
                Text(hud)
                    .font(.callout.monospacedDigit())
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, Space.s)
                    .glassEffect(.regular, in: .capsule)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .overlay {
            if case .ended(let reason) = terminal.phase {
                ContentUnavailableView {
                    Label("Process Exited", systemImage: "xmark.octagon")
                } description: {
                    Text(reason)
                } actions: {
                    Button("Back to Chat") { dismiss() }.buttonStyle(.glassProminent)
                }
                .foregroundStyle(.white)
                .background(Color.terminalBackground.opacity(0.85))
            }
        }
        .confirmationDialog("Allow the terminal to copy to your clipboard?",
                            isPresented: Binding { clipboardRequest != nil } set: { if !$0 { clipboardRequest = nil } },
                            titleVisibility: .visible, presenting: clipboardRequest) { text in
            Button("Allow") {
                terminal.clipboard = .allowed
                UIPasteboard.general.string = text
                copied += 1
            }
            Button("Don't Allow", role: .cancel) { terminal.clipboard = .denied }
        } message: { _ in
            Text("Something running in \(name) wants to copy text. It's asked once while this terminal is open.")
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .sensoryFeedback(.success, trigger: copied)
        // Attaching waits on the Mac; a reconnect or exit is the Mac's doing and stays quiet.
        .sensoryFeedback(.start, trigger: attached) { _, new in new }
        .onChange(of: terminal.phase) { old, new in
            if old == .attaching, new == .live { attached = true }
        }
        .onAppear { terminal.start() }
        .onDisappear { terminal.stop() }
        .task(id: lastTyped) {
            // Chrome fades after three seconds of typing; a tap near the top brings it back.
            guard lastTyped != .distantPast else { return }
            try? await Task.sleep(for: .seconds(3))
            withAnimation(Motion.smooth(reduceMotion)) { chromeVisible = false }
        }
        .task(id: hud) {
            guard hud != nil else { return }
            try? await Task.sleep(for: .seconds(1))
            withAnimation(Motion.smooth(reduceMotion)) { hud = nil }
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Label("Chat", systemImage: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.xs)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Back to chat")
            Spacer()
            Text(name)
                .font(.caption.monospaced())
                .lineLimit(1)
                .padding(.horizontal, Space.s)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
            Spacer()
            Color.clear.frame(width: 80, height: 1)
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        // Chrome over a fixed-size grid: it grows with Dynamic Type only so far.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .padding(.horizontal, Space.m)
        .padding(.top, Space.xs)
        .opacity(chromeVisible ? 1 : 0)
        .background(alignment: .top) {
            // A tap near the top edge while the chrome is hidden brings it back.
            if !chromeVisible {
                Color.clear.frame(height: 56).contentShape(.rect)
                    .onTapGesture { withAnimation(Motion.smooth(reduceMotion)) { chromeVisible = true } }
            }
        }
    }

    private var banner: String? {
        switch terminal.phase {
        case .attaching: return "Attaching…"
        case .reconnecting: return "Reconnecting…"
        case .live:
            if let notice = terminal.notice { return notice }
            if terminal.copyMode { return "\(model.mac.name) is scrolling back" }
            if let size = terminal.size, size.owner == "mac" { return "Sized for \(model.mac.name)" }
            return nil
        case .ended: return nil
        }
    }

    private func bannerView(_ text: String) -> some View {
        HStack(spacing: Space.xs) {
            if terminal.phase != .live { ProgressView().controlSize(.small).tint(.white) }
            Text(text).font(.footnote).contentTransition(.opacity)
            if terminal.notice == text {
                Button("Dismiss", systemImage: "xmark") { terminal.notice = nil }
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
        .glassEffect(.regular, in: .capsule)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .padding(.top, 60)
        .transition(.opacity)
    }

    /// OSC 52 from the remote side: never silently onto the clipboard.
    private func clipboard(_ text: String) {
        switch terminal.clipboard {
        case .allowed: UIPasteboard.general.string = text
        case .denied: break
        case .ask: if clipboardRequest == nil { clipboardRequest = text }
        }
    }

    private func typed() {
        lastTyped = .now
    }

    private func showSize(_ text: String) {
        withAnimation(Motion.snappy(reduceMotion)) { hud = text }
    }
}

/// SwiftTerm's `TerminalView`, wired to the model: output in, keys and size out, pinch for the font.
private struct TerminalHost: UIViewRepresentable {
    let terminal: TerminalModel
    @Binding var fontSize: Double
    let onTyped: () -> Void
    let onPinch: (String) -> Void
    let onClipboard: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: Self.font(fontSize))
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = UIColor(Color.terminalBackground)
        view.nativeForegroundColor = UIColor(Color.terminalForeground)
        view.backgroundColor = UIColor(Color.terminalBackground)
        view.optionAsMetaKey = true
        let bar = UIHostingController(rootView: KeyBar(keys: context.coordinator))
        bar.view.backgroundColor = .clear
        bar.view.frame = CGRect(x: 0, y: 0, width: 0, height: 52)
        bar.view.autoresizingMask = [.flexibleWidth]
        bar.sizingOptions = []
        view.inputAccessoryView = bar.view
        context.coordinator.view = view
        context.coordinator.bar = bar
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:))))
        terminal.output = { [weak view, weak coordinator = context.coordinator] bytes in
            coordinator?.lastOutput = .now
            view?.feed(byteArray: bytes)
        }
        terminal.grid = { [weak view] in
            guard let terminal = view?.getTerminal() else { return (80, 24) }
            return (terminal.cols, terminal.rows)
        }
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        context.coordinator.parent = self
        // Nothing more to type once the process is gone.
        if case .ended = terminal.phase, view.isFirstResponder { view.resignFirstResponder() }
        if view.font.pointSize != CGFloat(fontSize) { view.font = Self.font(fontSize) }
        // The Mac decides the size (its own client wins while it's typing); lay out to it.
        if let size = terminal.size, terminal.phase == .live {
            let grid = view.getTerminal()
            if grid.cols != size.cols || grid.rows != size.rows, size.owner == "mac" {
                context.coordinator.applyingMacSize = true
                view.resize(cols: size.cols, rows: size.rows)
                context.coordinator.applyingMacSize = false
            }
        }
    }

    static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.parent.terminal.output = nil
    }

    static func font(_ size: Double) -> UIFont { .monospacedSystemFont(ofSize: CGFloat(size), weight: .regular) }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate, KeyBarKeys {
        nonisolated deinit {}

        var parent: TerminalHost
        weak var view: TerminalView?
        var bar: UIHostingController<KeyBar>?
        var applyingMacSize = false
        /// The terminal answers some output itself (cursor position, device attributes); that isn't typing.
        var lastOutput = Date.distantPast
        private var resizeTask: Task<Void, Never>?
        private var pinchStart = 13.0

        init(_ parent: TerminalHost) { self.parent = parent }

        // TerminalViewDelegate

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            MainActor.assumeIsolated {
                parent.terminal.send(bytes)
                if Date.now.timeIntervalSince(lastOutput) > 0.1 { parent.onTyped() }
            }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                guard !applyingMacSize else { return }
                // Rotations and pinches settle before the Mac hears about it.
                resizeTask?.cancel()
                resizeTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    self?.parent.terminal.resize(cols: newCols, rows: newRows)
                }
            }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), AgentLink.opens(url) else { return }
            MainActor.assumeIsolated { UIApplication.shared.open(url) }
        }
        nonisolated func bell(source: TerminalView) {
            MainActor.assumeIsolated { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            // The remote side asking to set the clipboard (OSC 52); the screen asks the user first.
            MainActor.assumeIsolated { parent.onClipboard(String(decoding: content, as: UTF8.self)) }
        }
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        // KeyBarKeys

        var applicationCursor: Bool { view?.getTerminal().applicationCursor ?? false }
        var control: Bool {
            get { view?.controlModifier ?? false }
            set { view?.controlModifier = newValue }
        }

        func key(_ bytes: [UInt8]) {
            parent.terminal.send(bytes)
            parent.onTyped()
        }

        func hideKeyboard() { view?.resignFirstResponder() }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began: pinchStart = parent.fontSize
            case .changed:
                let size = min(18, max(10, (pinchStart * gesture.scale).rounded()))
                guard size != parent.fontSize else { return }
                parent.fontSize = size
                if let grid = view?.getTerminal() { parent.onPinch("\(Int(size)) pt · \(grid.cols)×\(grid.rows)") }
            default: break
            }
        }
    }
}
