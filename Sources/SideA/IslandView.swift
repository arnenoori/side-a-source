import AppKit
import SideACore
import SwiftUI

private final class IslandWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Never resized: a resizing window redraws a frame late and flickers, so it stays big enough for the largest card
/// and ignores the mouse outside the island.
@MainActor
final class IslandPanel {
    static let size = CGSize(width: 580, height: 660)
    private let island: Island
    private var window: NSPanel?
    private var hitRect = CGRect.zero
    private var observers: [Any] = []

    init(island: Island) { self.island = island }

    func update() {
        if island.visible {
            let window = self.window ?? make()
            let layout = layout(for: screen())
            if island.layout != layout { island.layout = layout }
            place(window)
            if !window.isVisible { window.orderFrontRegardless() }
            track()
        } else if let window, window.isVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, !self.island.visible else { return }
                window.orderOut(nil)
            }
        }
    }

    func makeKey() { window?.makeKey() }

    private func make() -> NSPanel {
        let window = IslandWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = true
        window.setAccessibilityTitle("Side A island")
        let hosting = NSHostingView(rootView: IslandRoot(island: island, hit: { [weak self] in self?.hitRect = $0; self?.track() }))
        hosting.sizingOptions = []
        window.contentView = hosting
        self.window = window
        observers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            },
            NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.track() }
            } as Any,
            NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                MainActor.assumeIsolated { self?.track() }
                return event
            } as Any,
        ]
        return window
    }

    private func track() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x - window.frame.minX, y: window.frame.maxY - mouse.y)
        let inside = island.visible && hitRect.insetBy(dx: -2, dy: -2).contains(point)
        if window.ignoresMouseEvents == inside { window.ignoresMouseEvents = !inside }
    }

    private func screen() -> NSScreen? {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        if UserDefaults.standard.string(forKey: Island.screenKey) == "active" {
            return NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        }
        return notched ?? NSScreen.main
    }

    private func layout(for screen: NSScreen?) -> Island.Layout {
        guard let screen, screen.safeAreaInsets.top > 0 else { return Island.Layout(notch: nil) }
        let left = screen.auxiliaryTopLeftArea?.width ?? 0, right = screen.auxiliaryTopRightArea?.width ?? 0
        let width = left > 0 && right > 0 ? screen.frame.width - left - right : 200
        return Island.Layout(notch: CGSize(width: width, height: screen.safeAreaInsets.top))
    }

    private func place(_ window: NSPanel) {
        guard let screen = screen() else { return }
        let top = island.layout.notch == nil ? screen.visibleFrame.maxY : screen.frame.maxY
        let frame = NSRect(x: (screen.frame.midX - Self.size.width / 2).rounded(), y: top - Self.size.height,
                           width: Self.size.width, height: Self.size.height)
        if window.frame != frame { window.setFrame(frame, display: false) }
    }
}

struct IslandRoot: View {
    @Bindable var island: Island
    var hit: (CGRect) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    /// The window is made on the first show; starting at rest lets that first show grow out of the notch too.
    @State private var appeared: Bool

    init(island: Island, settled: Bool = false, hit: @escaping (CGRect) -> Void = { _ in }) {
        self.island = island
        self.hit = hit
        _appeared = State(initialValue: settled)
    }

    private var stage: IslandStage {
        guard appeared else { return .rest }
        if let item = island.current, island.expanded { return .request(item.id) }
        if let event = island.event { return .event(event.id) }
        if island.expanded, !island.ready.isEmpty { return .ready }
        if !island.pending.isEmpty || !island.ready.isEmpty { return .compact }
        return .rest
    }

    private var notched: Bool { island.layout.notch != nil }
    private var large: Bool { stage != .rest && stage != .compact }
    private var rest: CGSize { island.layout.notch ?? CGSize(width: 200, height: 38) }

    var body: some View {
        MorphLayout(current: stage) {
            Color.clear.frame(width: rest.width, height: rest.height).layoutValue(key: MorphKey.self, value: IslandStage.rest)
            content
        }
        .padding(.horizontal, ear)
        .background(Color.black, in: outline)
        .overlay { outline.stroke(rim, lineWidth: contrast == .increased ? 2 : 1) }
        .clipShape(outline)
        .shadow(color: .black.opacity(stage == .rest ? 0 : large ? 0.45 : 0.25), radius: large ? 18 : 6, y: large ? 8 : 3)
        .opacity(notched || stage != .rest ? 1 : 0)
        .contentShape(outline)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { hit($0) }
        .padding(.top, notched ? 0 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(animation, value: stage)
        .onAppear { DispatchQueue.main.async { appeared = true } }
        .animation(animation, value: island.pending.map(\.id))
        .animation(animation, value: island.ready.map(\.id))
        .environment(\.colorScheme, .dark)
    }

    private var animation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        return large ? .spring(duration: 0.46, bounce: 0.2) : .spring(duration: 0.4, bounce: 0)
    }

    private var ear: CGFloat { notched ? (large ? 12 : stage == .compact ? 6 : 0) : 0 }
    private var radius: CGFloat { large ? 24 : notched ? (stage == .rest ? 9 : 13) : 19 }
    private var outline: IslandShape { IslandShape(ear: ear, radius: radius, notched: notched) }

    private var rim: LinearGradient {
        let alarm = island.expanded && island.current?.request.risk == .destructive && large
        let tint: Color = alarm ? Color(red: 1, green: 0.4, blue: 0.35) : .white
        let strength = stage == .rest ? 0 : contrast == .increased ? 0.7 : alarm ? 0.45 : 0.13
        return LinearGradient(colors: [tint.opacity(notched ? 0 : strength), tint.opacity(strength)], startPoint: .top, endPoint: .bottom)
    }

    private var swap: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .modifier(active: Soften(on: true), identity: Soften(on: false)).animation(.easeOut(duration: 0.26).delay(0.07)),
                           removal: .opacity.animation(.easeOut(duration: 0.12)))
    }

    @ViewBuilder private var content: some View {
        switch stage {
        case .request:
            if let item = island.current {
                RequestCard(island: island, item: item).id(item.id).transition(swap).layoutValue(key: MorphKey.self, value: stage)
            }
        case .event:
            if let event = island.event {
                EventStrip(island: island, event: event).id(event.id).transition(swap).layoutValue(key: MorphKey.self, value: stage)
            }
        case .ready:
            ReadyList(island: island).transition(swap).layoutValue(key: MorphKey.self, value: stage)
        case .compact:
            CompactStrip(island: island).transition(swap).layoutValue(key: MorphKey.self, value: stage)
        case .rest:
            EmptyView()
        }
    }
}

private enum IslandStage: Hashable { case rest, compact, request(UUID), event(UUID), ready }

private struct MorphKey: LayoutValueKey {
    static let defaultValue: IslandStage? = nil
}

/// Sized by the incoming content only; sizing by content still fading out snaps the shape when the removal ends.
private struct MorphLayout: Layout {
    let current: IslandStage

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        (subviews.last { $0[MorphKey.self] == current } ?? subviews.first)?.sizeThatFits(.unspecified) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: .unspecified)
        }
    }
}

private struct Soften: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.blur(radius: on ? 8 : 0).opacity(on ? 0 : 1).scaleEffect(on ? 0.96 : 1, anchor: .top)
    }
}

private struct IslandShape: InsettableShape {
    var ear: CGFloat
    var radius: CGFloat
    let notched: Bool
    var inset: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, radius) }
        set { ear = newValue.first; radius = newValue.second }
    }

    func inset(by amount: CGFloat) -> IslandShape { var shape = self; shape.inset += amount; return shape }

    func path(in rect: CGRect) -> Path {
        guard notched else {
            return RoundedRectangle(cornerRadius: max(radius - inset, 0), style: .continuous).path(in: rect.insetBy(dx: inset, dy: inset))
        }
        let rect = CGRect(x: rect.minX + inset, y: rect.minY, width: rect.width - inset * 2, height: rect.height - inset)
        let left = rect.minX + ear, right = rect.maxX - ear
        let corner = max(0, min(radius - inset, (right - left) / 2, rect.height - ear))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: left, y: rect.maxY), radius: ear)
        path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.maxY), radius: corner)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.minY), radius: corner)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: ear)
        path.closeSubpath()
        return path
    }
}

private struct NotchBand<Leading: View, Trailing: View>: View {
    let notch: CGSize?
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        if let notch {
            HStack(spacing: 0) {
                leading.frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: notch.width + 12)
                trailing.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: notch.height)
        } else {
            HStack(spacing: 8) {
                leading
                Spacer(minLength: 8)
                trailing
            }
        }
    }
}

private struct CompactStrip: View {
    let island: Island

    private var item: Island.Pending? { island.current }
    private var count: Int { item == nil ? island.ready.count : island.pending.count }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let item { AgentGlyph(agent: item.request.agent, size: 14) } else { Disc(size: 16) }
            }
            .padding(.leading, 12)
            if let notch = island.layout.notch {
                Spacer(minLength: notch.width)
            } else {
                Text(item?.request.headline ?? (count == 1 ? "\(island.ready[0].title) is done" : "\(count) sessions are done"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1).padding(.horizontal, 10)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                if let item {
                    Beacon(tint: item.request.risk == .destructive ? .red : .orange)
                } else {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.green)
                }
                if count > 1 {
                    Text("\(count)").font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
                        .contentTransition(.numericText())
                }
            }
            .padding(.trailing, 14)
        }
        .frame(width: (island.layout.notch?.width ?? 200) + (island.layout.notch == nil ? 60 : 96),
               height: island.layout.notch?.height ?? 38)
        .contentShape(Rectangle())
        .onHover { if $0 { island.expand() } }
        .onTapGesture { island.expand() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item == nil ? "\(count) session\(count == 1 ? " is" : "s are") done"
                            : "\(count) permission request\(count == 1 ? "" : "s") waiting")
        .accessibilityHint(item == nil ? "Shows them. Control Option G goes to the latest." : "Opens the request. Control Option I from anywhere.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { island.expand() }
    }
}

private struct Beacon: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().fill(tint).frame(width: 7, height: 7)
            .background {
                if !reduceMotion {
                    Circle().stroke(tint, lineWidth: 1.5)
                        .phaseAnimator([false, true]) { ring, out in
                            ring.scaleEffect(out ? 2.6 : 1).opacity(out ? 0 : 0.7)
                        } animation: { out in out ? .easeOut(duration: 1.6) : nil }
                }
            }
            .accessibilityHidden(true)
    }
}

private struct Disc: View {
    var size: CGFloat = 16
    var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let sheen: [Color] = [Color(white: 0.8), Color(red: 0.68, green: 0.84, blue: 0.96), Color(white: 0.92),
                                         Color(red: 0.96, green: 0.76, blue: 0.88), Color(white: 0.74), Color(red: 0.94, green: 0.9, blue: 0.66),
                                         Color(white: 0.8)]

    var body: some View {
        let disc = ZStack {
            Circle().fill(AngularGradient(colors: Self.sheen, center: .center))
            Circle().fill(Color(white: 0.55)).frame(width: size * 0.42, height: size * 0.42)
            Circle().fill(.black).frame(width: size * 0.18, height: size * 0.18)
        }
        .frame(width: size, height: size)
        Group {
            if spinning && !reduceMotion {
                disc.phaseAnimator([0.0, 360.0]) { view, angle in view.rotationEffect(.degrees(angle)) } animation: { angle in
                    angle == 360 ? .linear(duration: 1.8) : nil
                }
            } else {
                disc
            }
        }
        .accessibilityHidden(true)
    }
}

private struct AgentGlyph: View {
    let agent: IslandAgent
    var size: CGFloat = 18
    var body: some View {
        Image(systemName: agent == .claude ? "asterisk" : "chevron.left.forwardslash.chevron.right")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(agent == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(white: 0.92))
            .frame(width: size + 6, height: size + 6)
            .accessibilityHidden(true)
    }
}

private struct RequestCard: View {
    let island: Island
    let item: Island.Pending
    @FocusState private var focused: Field?
    private enum Field { case allow, deny }

    private var request: IslandRequest { item.request }
    private var destructive: Bool { request.risk == .destructive }
    private var notched: Bool { island.layout.notch != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NotchBand(notch: island.layout.notch) {
                HStack(spacing: 5) {
                    AgentGlyph(agent: request.agent, size: 12)
                    Text(request.agent.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                }
            } trailing: { controls }
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    context
                    HStack(spacing: 8) {
                        Text(QuestionForm.inline(request.action) ? "A question for you" : request.headline).font(.system(size: 17, weight: .semibold)).tracking(-0.2).foregroundStyle(.white)
                        if let reason = request.riskReason, destructive {
                            Label(reason, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.red.opacity(0.2), in: Capsule())
                                .foregroundStyle(Color(red: 1, green: 0.58, blue: 0.52))
                        }
                    }
                    switch request.action {
                    case .question(let questions): QuestionForm(island: island, item: item, questions: questions)
                    case .plan(let plan): PlanText(plan: plan)
                    default: if !request.detail.isEmpty { ActionDetail(action: request.action) }
                    }
                    if let reason = request.reason {
                        Text(reason).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                    }
                    if let handBack = item.handBackAt {
                        HandBack(at: handBack, total: handBack.timeIntervalSince(item.arrived), label: item.request.headless ? "Automated run: denied unless you answer in" : "Goes back to Codex's own prompt in")
                    }
                }
                switch request.action {
                case .question: EmptyView()
                case .plan: PlanButtons(island: island, item: item)
                default: buttons
                }
                footer
            }
            .padding(.top, notched ? 6 : 12)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .padding(.top, notched ? 0 : 14)
        .frame(width: 460, alignment: .leading)
        .onChange(of: island.focusRequest) { focused = destructive ? .deny : .allow }
        .onExitCommand { island.collapse() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.agent.title) \(request.tool == "AskUserQuestion" ? "question" : request.tool == "ExitPlanMode" ? "plan" : "permission request")")
        .accessibilityAction(named: "Deny") { island.answer(.deny(nil), item.id) }
        .accessibilityAction(named: "Show terminal") { island.showTerminal(item) }
    }

    private var context: some View {
        let place = [request.project == item.title ? nil : request.project, item.account].compactMap { $0 }.joined(separator: " · ")
        return (Text(item.title).foregroundStyle(.white.opacity(0.9))
                + Text(place.isEmpty ? "" : "  ·  \(place)").foregroundStyle(.white.opacity(0.5)))
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
    }

    private var controls: some View {
        HStack(spacing: 2) {
            if island.pending.count > 1 {
                Button { island.step(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous request")
                Text("\(island.index + 1) of \(island.pending.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                Button { island.step(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next request")
            }
            Button { island.collapse() } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel("Collapse")
                .help("Collapse into the notch")
        }
        .buttonStyle(IconButtonStyle())
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button { island.answer(.deny(nil), item.id) } label: { Text("Deny").frame(maxWidth: .infinity) }
                .buttonStyle(IslandButtonStyle(kind: destructive ? .primary : .secondary))
                .focused($focused, equals: .deny)
                .accessibilityHint("Control Option N")
            if request.offersAlways, let first = request.suggestions.first {
                if request.suggestions.count == 1 {
                    Button { island.always(first) } label: { Text(request.agent == .codex ? "This session" : "Always").frame(maxWidth: .infinity) }
                        .buttonStyle(IslandButtonStyle(kind: .secondary))
                        .help(first.title)
                        .accessibilityLabel(first.title)
                        .accessibilityHint("Control Option A")
                } else {
                    Menu {
                        ForEach(request.suggestions, id: \.json) { suggestion in
                            Button(suggestion.title) { island.always(suggestion) }
                        }
                    } label: { Text("Always…").frame(maxWidth: .infinity) }
                        .menuStyle(.button).buttonStyle(IslandButtonStyle(kind: .secondary))
                        .menuIndicator(.hidden)
                        .accessibilityLabel("Always allow options")
                }
            }
            Button { island.answer(.allow, item.id, confirmed: true) } label: { Text(destructive ? "Allow anyway" : "Allow").frame(maxWidth: .infinity) }
                .buttonStyle(IslandButtonStyle(kind: destructive ? .danger : .primary))
                .focused($focused, equals: .allow)
                .keyboardShortcut(destructive ? nil : .defaultAction)
                .accessibilityHint(destructive ? "Needs a click; no shortcut approves this." : "Control Option Y")
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let origin = item.origin {
                Text("No terminal: started by \(origin)")
                    .lineLimit(1).truncationMode(.middle)
                    .help("It runs without a terminal (claude -p), so only Side A can answer it.")
            } else {
                Button("Show terminal") { island.showTerminal(item) }
                    .fixedSize()
                    .accessibilityHint("Control Option T")
                Button("Answer in terminal") { island.answerInTerminal(item) }
                    .fixedSize()
            }
            Spacer(minLength: 8)
            Group {
                if destructive {
                    Text("Needs a click")
                } else if case .question(let questions) = request.action {
                    Keycap(keys: "⌃⌥1–\(min(questions.map(\.options.count).max() ?? 4, 4))", label: "choose")
                } else if case .plan = request.action {
                    HStack(spacing: 10) { Keycap(keys: "⌃⌥Y", label: "approve"); Keycap(keys: "⌃⌥N", label: "keep planning") }
                } else {
                    HStack(spacing: 10) { Keycap(keys: "⌃⌥Y", label: "allow"); Keycap(keys: "⌃⌥N", label: "deny") }
                }
            }
            .foregroundStyle(.white.opacity(0.45))
            .accessibilityHidden(true)
        }
        .buttonStyle(QuietButtonStyle())
        .font(.system(size: 11, weight: .medium))
    }
}

private struct Keycap: View {
    let keys: String
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(keys).font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 4).padding(.vertical, 1.5)
                .background(.white.opacity(0.1), in: .rect(cornerRadius: 4, style: .continuous))
            Text(label)
        }
        .fixedSize()
    }
}

private struct HandBack: View {
    let at: Date
    let total: TimeInterval
    let label: String
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(at.timeIntervalSince(context.date)))
            HStack(spacing: 6) {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 2)
                    Circle().trim(from: 0, to: min(1, Double(left) / max(total, 1)))
                        .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: left)
                }
                .frame(width: 11, height: 11)
                .accessibilityHidden(true)
                Text("\(label) \(left / 60):\(String(format: "%02d", left % 60))")
            }
            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
        }
    }
}

private struct ActionDetail: View {
    let action: IslandAction
    var body: some View {
        Group {
            switch action {
            case .edit(let path, let removed, let added):
                VStack(alignment: .leading, spacing: 4) {
                    Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.head)
                    DiffLines(text: removed, sign: "−", tint: .red)
                    DiffLines(text: added, sign: "+", tint: .green)
                }
            case .write(let path, let content):
                VStack(alignment: .leading, spacing: 4) {
                    Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.head)
                    DiffLines(text: content, sign: "+", tint: .green)
                }
            case .command(let command):
                ScrollView {
                    (Text("$ ").foregroundStyle(.white.opacity(0.35)) + Text(command))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 96).fixedSize(horizontal: false, vertical: true)
            default:
                let request = IslandRequest(agent: .claude, cwd: nil, tool: "", action: action)
                ScrollView { Text(request.detail).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 96).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1) }
    }
}

private struct DiffLines: View {
    let text: String
    let sign: String
    let tint: Color
    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(6).enumerated()), id: \.offset) { _, line in
                    (Text("\(sign) ").foregroundStyle(tint) + Text(line)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(tint.opacity(0.14))
                }
                if lines.count > 6 {
                    Text("\(lines.count - 6) more lines").foregroundStyle(.white.opacity(0.45)).padding(.top, 3)
                }
            }
            .clipShape(.rect(cornerRadius: 5, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(sign == "+" ? "Adds" : "Removes"): \(text.prefix(300))")
        }
    }
}

private struct IslandButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    let kind: Kind
    var pill = false

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        IslandButton(configuration: configuration, kind: kind, pill: pill)
    }
}

private struct IslandButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: IslandButtonStyle.Kind
    let pill: Bool
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: pill ? 15 : 11, style: .continuous)
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, pill ? 16 : 10)
            .frame(maxWidth: pill ? nil : .infinity)
            .frame(height: pill ? 30 : 34)
            .foregroundStyle(foreground)
            .background(fill, in: shape)
            .overlay { shape.strokeBorder(stroke, lineWidth: 1) }
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: pill ? 18 : 14, style: .continuous)
                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2.5).padding(-3)
                }
            }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .focusEffectDisabled()
            .onHover { hovering = $0 && enabled }
    }

    private var foreground: Color {
        switch kind {
        case .primary: .black
        case .secondary: .white
        case .danger: contrast == .increased ? .white : Color(red: 1, green: 0.62, blue: 0.57)
        }
    }

    private var fill: Color {
        let lift = configuration.isPressed ? 2.0 : hovering ? 1.0 : 0
        switch kind {
        case .primary: return Color(white: 1 - lift * 0.07)
        case .secondary: return .white.opacity(0.12 + lift * 0.05)
        case .danger: return contrast == .increased ? Color(red: 0.75, green: 0.12, blue: 0.12) : Color.red.opacity(0.2 + lift * 0.07)
        }
    }

    private var stroke: Color {
        if contrast == .increased { return .white.opacity(0.8) }
        return kind == .danger ? Color.red.opacity(0.4) : .clear
    }
}

private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View { QuietButton(configuration: configuration, icon: false) }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View { QuietButton(configuration: configuration, icon: true) }
}

private struct QuietButton: View {
    let configuration: ButtonStyleConfiguration
    let icon: Bool
    @Environment(\.isFocused) private var focused
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(icon ? .system(size: 11, weight: .bold) : nil)
            .frame(width: icon ? 22 : nil, height: icon ? 22 : nil)
            .padding(.horizontal, icon ? 0 : 6).padding(.vertical, icon ? 0 : 3)
            .foregroundStyle(.white.opacity(hovering || focused || contrast == .increased ? 0.95 : 0.55))
            .background(.white.opacity(hovering ? 0.12 : 0), in: Capsule())
            .overlay { if focused { Capsule().strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2) } }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .padding(.horizontal, icon ? 0 : -6)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .focusEffectDisabled()
            .onHover { hovering = $0 }
    }
}

private struct EventStrip: View {
    let island: Island
    let event: Island.Event

    var body: some View {
        Group {
            if let notch = island.layout.notch {
                VStack(alignment: .leading, spacing: 8) {
                    NotchBand(notch: notch) {
                        HStack(spacing: 6) {
                            icon
                            Text(kind).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                        }
                    } trailing: { EmptyView() }
                    HStack(spacing: 12) { text; Spacer(minLength: 0); action }
                }
            } else {
                HStack(spacing: 12) { icon; text; Spacer(minLength: 0); action }
                    .padding(.top, 14)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(width: 380, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { island.dismissEvent() }
        .accessibilityElement(children: .combine)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Text(event.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var icon: some View {
        if event.kind == .track {
            Disc(size: 16, spinning: true)
        } else {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
        }
    }

    @ViewBuilder private var action: some View {
        if event.kind == .finished, let ready = island.ready.first(where: { $0.finish.pid == event.pid && $0.finish.cwd == event.cwd }) {
            HStack(spacing: 6) {
                Button { island.openReply(ready) } label: { Image(systemName: "arrowshape.turn.up.left.fill") }
                    .buttonStyle(IconButtonStyle())
                    .help("Give it its next task")
                    .accessibilityLabel("Reply")
                    .accessibilityHint("Control Option R")
                Button("Go") { island.go(ready) }
                    .buttonStyle(IslandButtonStyle(kind: .primary, pill: true))
                    .accessibilityHint("Control Option G")
            }
        } else if event.kind == .waiting, event.pid != nil {
            Button("Show") { island.reveal(pid: event.pid, cwd: event.cwd, title: event.title); island.dismissEvent() }
                .buttonStyle(IslandButtonStyle(kind: .secondary, pill: true))
        }
    }

    private var kind: String {
        switch event.kind {
        case .track: "Track change"
        case .limit: "Limit"
        case .waiting: "Waiting"
        case .finished: "Done"
        }
    }

    private var symbol: String {
        switch event.kind {
        case .track: "opticaldisc.fill"
        case .limit: "exclamationmark.triangle.fill"
        case .waiting: "bubble.left.fill"
        case .finished: "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .track: Color(white: 0.85)
        case .limit: .orange
        case .waiting: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .finished: .green
        }
    }
}

private struct ReadyList: View {
    let island: Island

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NotchBand(notch: island.layout.notch) {
                HStack(spacing: 6) {
                    Disc(size: 14)
                    Text("Ready for you").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                }
            } trailing: {
                HStack(spacing: 6) {
                    Button("Clear") { island.clearReady() }.buttonStyle(QuietButtonStyle()).font(.system(size: 11, weight: .medium))
                    Button { island.collapse() } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(IconButtonStyle()).accessibilityLabel("Collapse")
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(island.ready.prefix(5)) { item in
                    ReadyRow(island: island, item: item, first: item.id == island.ready.first?.id)
                }
                if island.ready.count > 5 {
                    Text("and \(island.ready.count - 5) more").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).padding(.leading, 10)
                }
            }
            .padding(.horizontal, -10)
            .padding(.top, island.layout.notch == nil ? 10 : 4)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .padding(.top, island.layout.notch == nil ? 14 : 0)
        .frame(width: 440, alignment: .leading)
        .onHover { if !$0, island.pending.isEmpty, island.replying == nil { island.collapse() } }
        .onExitCommand { island.collapse() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions ready for you")
    }
}

private struct ReadyRow: View {
    let island: Island
    let item: Island.Ready
    let first: Bool
    @State private var hovering = false
    @State private var text = ""
    @FocusState private var typing: Bool

    private var open: Bool { island.replying == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row
            if open { field.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.white.opacity(hovering || open ? 0.06 : 0), in: .rect(cornerRadius: 14, style: .continuous))
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: open)
        .onHover { hovering = $0 }
        .onChange(of: island.focusRequest) { if open { typing = true } }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Next task for \(item.title)…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineLimit(1...5)
                    .focused($typing)
                    .onSubmit { island.reply(item, text) }
                    .onExitCommand { island.replying = nil }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("Next task for \(item.title)")
                Button(island.canReply(item) ? "Send" : "Copy") { island.reply(item, text) }
                    .buttonStyle(IslandButtonStyle(kind: .primary, pill: true))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(island.canReply(item) ? "Wakes the session with this as its next task. ⌥↩ for a new line."
                 : "This session can't be woken from here: Copy puts it on the clipboard and opens its terminal.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
        .onAppear { typing = true }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 10) {
            AgentGlyph(agent: item.finish.agent, size: 13)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(item.at, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    }
                }
                if !item.finish.summary.isEmpty {
                    Text(item.finish.summary).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button { open ? (island.replying = nil) : island.openReply(item) } label: { Image(systemName: "arrowshape.turn.up.left.fill") }
                .buttonStyle(IconButtonStyle())
                .help("Give it its next task")
                .accessibilityLabel("Reply to \(item.title)")
                .accessibilityHint("Control Option R")
            Button("Go") { island.go(item) }
                .buttonStyle(IslandButtonStyle(kind: first ? .primary : .secondary, pill: true))
                .disabled(item.finish.pid == nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title) is done. \(item.finish.summary)")
        .accessibilityAction(named: "Go to its terminal") { island.go(item) }
        .accessibilityAction(named: "Reply") { island.openReply(item) }
    }
}

/// One question at a time once there are several, so a long form never runs past the island's fixed window.
private struct QuestionForm: View {
    let island: Island
    let item: Island.Pending
    let questions: [IslandQuestion]
    private var picked: [String: [String]] {
        get { island.drafts[item.id]?.picked ?? [:] }
        nonmutating set { island.drafts[item.id, default: .init()].picked = newValue }
    }
    private var other: [String: String] {
        get { island.drafts[item.id]?.other ?? [:] }
        nonmutating set { island.drafts[item.id, default: .init()].other = newValue }
    }
    private var step: Int {
        get { island.drafts[item.id]?.step ?? 0 }
        nonmutating set { island.drafts[item.id, default: .init()].step = newValue }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var single: Bool { questions.count == 1 && !questions[0].multiSelect }
    private var paged: Bool { questions.count > 1 }

    private var last: Bool { step == questions.count - 1 }
    private var question: IslandQuestion { questions[min(step, questions.count - 1)] }

    /// A lone question too long to be the headline; it scrolls with its options instead.
    static func inline(_ action: IslandAction) -> Bool {
        guard case .question(let questions) = action, questions.count == 1 else { return false }
        return questions[0].question.count > 140
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if paged { tabs }
            page(question).id(step).transition(.opacity)
            if !single { buttons }
        }
        .onAppear(perform: preselect)
        .onChange(of: island.choice) {
            if let choice = island.choice, question.options.indices.contains(choice.option) { pick(question, question.options[choice.option].label) }
        }
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                let done = !answer(question).isEmpty
                Button { go(index) } label: {
                    HStack(spacing: 4) {
                        if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                        Text(question.header.flatMap { $0.isEmpty ? nil : $0 } ?? "Question \(index + 1)").lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(index == step ? 0.95 : 0.55))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.white.opacity(index == step ? 0.16 : 0.06), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Question \(index + 1) of \(questions.count)" + (done ? ", answered" : ""))
                .accessibilityAddTraits(index == step ? .isSelected : [])
            }
        }
    }

    private func page(_ question: IslandQuestion) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if paged || Self.inline(item.request.action) {
                    Text(question.question).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true).padding(.bottom, 2)
                }
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    OptionRow(option: option, number: single && index < 4 ? index + 1 : nil, multiple: question.multiSelect,
                              selected: picked[question.question]?.contains(option.label) == true) { pick(question, option.label) }
                }
                TextField("Something else…", text: Binding(get: { other[question.question] ?? "" }, set: { other[question.question] = $0 }))
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.05), in: .rect(cornerRadius: 11, style: .continuous))
                    .onSubmit { single || last ? send() : go(step + 1) }
                    .accessibilityLabel("Another answer to: \(question.question)")
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(paged ? "Question \(step + 1) of \(questions.count)" : "")
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if paged && step > 0 {
                Button { go(step - 1) } label: { Text("Back").frame(maxWidth: .infinity) }
                    .buttonStyle(IslandButtonStyle(kind: .secondary))
            }
            if paged && !last && recommendedOnly {
                Button { send() } label: { Text("Send recommended").frame(maxWidth: .infinity) }
                    .buttonStyle(IslandButtonStyle(kind: .secondary))
            }
            if paged && !last {
                Button { go(step + 1) } label: { Text("Next").frame(maxWidth: .infinity) }
                    .buttonStyle(IslandButtonStyle(kind: .primary))
                    .disabled(answer(question).isEmpty)
            } else {
                Button { send() } label: { Text(recommendedOnly ? "Send recommended answers" : "Send answers").frame(maxWidth: .infinity) }
                    .buttonStyle(IslandButtonStyle(kind: .primary))
                    .disabled(!complete)
                    .help(complete ? "" : "Answer every question first")
            }
        }
    }

    private func go(_ index: Int) {
        guard questions.indices.contains(index), index != step else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { step = index }
        island.announce("Question \(index + 1) of \(questions.count). \(questions[index].question)", high: false)
    }

    private func answer(_ question: IslandQuestion) -> String {
        let typed = (other[question.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ((picked[question.question] ?? []) + (typed.isEmpty ? [] : [typed])).joined(separator: ", ")
    }

    private var complete: Bool { questions.allSatisfy { !answer($0).isEmpty } }

    /// Every answer is still the one Claude recommended, so one click accepts them all.
    private var recommendedOnly: Bool {
        questions.allSatisfy { question in
            (other[question.question] ?? "").isEmpty
                && picked[question.question] == question.options.filter(\.recommended).map(\.label) && !(picked[question.question] ?? []).isEmpty
        }
    }

    /// Starts each single-choice question on Claude's recommended answer.
    private func preselect() {
        for question in questions where !question.multiSelect && picked[question.question] == nil {
            if let option = question.options.first(where: \.recommended) { picked[question.question] = [option.label] }
        }
    }

    private func pick(_ question: IslandQuestion, _ label: String) {
        if single { return island.answer(.answers([question.question: label], input: item.request.input), item.id) }
        var chosen = picked[question.question] ?? []
        if question.multiSelect {
            if let index = chosen.firstIndex(of: label) { chosen.remove(at: index) } else { chosen.append(label) }
        } else {
            chosen = [label]
        }
        picked[question.question] = chosen
        // A single choice settles its question; let the pick show for a beat, then turn the page.
        if paged, !question.multiSelect, !last {
            let from = step
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { if step == from { go(from + 1) } }
        }
    }

    private func send() {
        guard complete else { return go(questions.firstIndex { answer($0).isEmpty } ?? step) }
        island.answer(.answers(Dictionary(questions.map { ($0.question, answer($0)) }) { first, _ in first }, input: item.request.input), item.id)
    }
}

private struct OptionRow: View {
    let option: IslandQuestion.Option
    let number: Int?
    let multiple: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Group {
                    if let number {
                        Text("\(number)").font(.system(size: 11, weight: .bold).monospacedDigit())
                            .frame(width: 18, height: 18).background(.white.opacity(0.12), in: .rect(cornerRadius: 5, style: .continuous))
                    } else {
                        Image(systemName: selected ? (multiple ? "checkmark.square.fill" : "largecircle.fill.circle") : (multiple ? "square" : "circle"))
                            .font(.system(size: 13)).frame(width: 18)
                    }
                }
                .foregroundStyle(.white.opacity(0.8))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        if option.recommended {
                            Text("Recommended").font(.system(size: 10, weight: .semibold)).foregroundStyle(.black)
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(.white.opacity(0.85), in: Capsule())
                        }
                    }
                    if let description = option.description, !description.isEmpty, description.caseInsensitiveCompare(option.label) != .orderedSame {
                        Text(description).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(selected ? 0.16 : hovering ? 0.1 : 0.06), in: .rect(cornerRadius: 11, style: .continuous))
            .contentShape(.rect(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(option.title + (option.recommended ? ", recommended" : "") + (option.description.map { ", \($0)" } ?? ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(number.map { "Control Option \($0)" } ?? "")
    }
}

/// The plan as Claude wrote it: headings bold, lists and inline Markdown kept, long plans scroll.
private struct PlanText: View {
    let plan: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(plan.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
                    line(String(raw))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 260)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(.white.opacity(0.07), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1) }
    }

    @ViewBuilder private func line(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Color.clear.frame(height: 2)
        } else if trimmed.hasPrefix("#") {
            Text(inline(trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                .font(.system(size: trimmed.hasPrefix("# ") ? 15 : 13, weight: .semibold)).foregroundStyle(.white).padding(.top, 2)
        } else {
            Text(inline(raw)).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.85))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

private struct PlanButtons: View {
    let island: Island
    let item: Island.Pending
    @State private var revising = false
    @State private var feedback = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if revising {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("What should change?", text: $feedback, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.white).lineLimit(1...5)
                        .focused($typing)
                        .onSubmit(send)
                        .onExitCommand { revising = false }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.white.opacity(0.08), in: .rect(cornerRadius: 10, style: .continuous))
                    Button("Send", action: send)
                        .buttonStyle(IslandButtonStyle(kind: .primary, pill: true))
                        .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .onAppear { island.focus(); typing = true }
            } else {
                HStack(spacing: 8) {
                    Button { revising = true } label: { Text("Revise…").frame(maxWidth: .infinity) }
                        .buttonStyle(IslandButtonStyle(kind: .secondary))
                        .accessibilityHint("Tell Claude what to change; it keeps planning.")
                    Button { island.answer(.approvePlan(input: item.request.input, acceptEdits: true), item.id) } label: {
                        Text("Accept edits").frame(maxWidth: .infinity)
                    }
                        .buttonStyle(IslandButtonStyle(kind: .secondary))
                        .help("Approve, and let Claude make file edits without asking")
                        .accessibilityLabel("Approve and accept edits")
                    Button { island.answer(.approvePlan(input: item.request.input, acceptEdits: false), item.id) } label: {
                        Text("Approve").frame(maxWidth: .infinity)
                    }
                        .buttonStyle(IslandButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                        .accessibilityHint("Control Option Y")
                }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: revising)
    }

    private func send() {
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        island.answer(.deny("The user wants changes to the plan before you start: \(text)"), item.id)
    }
}
