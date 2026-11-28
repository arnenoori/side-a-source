import SideAProtocol
import SwiftUI

struct ModelEffortSheet: View {
    struct OtherAgent {
        let agent: AgentProvider
        let models: [ModelOption]
        let accounts: [RemoteAccount]
        @Binding var modelID: String?
        @Binding var effort: Effort?
        @Binding var accountID: String?
    }

    struct ModeRow {
        let offered: [PermissionMode]
        let current: PermissionMode
        let busy: Bool
        let set: (PermissionMode) -> Void
    }

    let models: [ModelOption]
    var offersDefault = false
    @Binding var modelID: String?
    @Binding var effort: Effort?
    var canChangeModel = true
    var canChangeEffort: (ModelOption) -> Bool = { _ in true }
    var note: String?
    var other: OtherAgent?
    var mode: ModeRow?
    var apply: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var pickedMode: PermissionMode?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsStops = false
    @Namespace private var focus

    private var chosen: ModelOption? { models.first { $0.id == modelID } }
    private var handingOff: Bool { other?.modelID != nil }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                // Not a List: its rows are separate cells, and the selection's fill has to travel between them.
                ScrollView {
                    VStack(spacing: Space.xxs) {
                        if offersDefault { defaultRow }
                        ForEach(models, id: \.id) { option in
                            row(option, selected: !handingOff && option.id == modelID, effort: $effort, canChange: canChangeModel || option.id == modelID,
                                canChangeEffort: canChangeEffort(option)) { pick(option.id) }
                        }
                    }
                    .padding(.horizontal, Space.m)
                    .padding(.top, Space.xs)
                    if let other { otherSection(other) }
                    if let mode { modeSection(mode) }
                    if let note {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.m * 2)
                            .padding(.top, Space.s)
                    }
                }
                .onChange(of: showsStops) { _, shown in
                    // A medium detent can leave the stops of a lower row out of view.
                    if shown { withAnimation(Motion.smooth(reduceMotion)) { proxy.scrollTo("stops", anchor: .bottom) } }
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let apply {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") {
                            apply()
                            if let mode, let pickedMode, pickedMode != mode.current { mode.set(pickedMode) }
                            dismiss()
                        }
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
        }
        .presentationDetents(other == nil && mode == nil ? [.medium] : [.medium, .large])
        .presentationContentInteraction(.scrolls)
        .sensoryFeedback(.selection, trigger: modelID)
        .sensoryFeedback(.selection, trigger: other?.modelID)
        .onAppear { showsStops = (chosen?.efforts.count ?? 0) > 1 && models.count == 1 }
    }

    private var defaultRow: some View {
        let selected = modelID == nil && !handingOff
        return Button { pick(nil) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Default")
                Text(models.first { $0.isDefault == true }?.title ?? "The agent's own choice")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!canChangeModel && modelID != nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .focusRow(selected: selected, in: focus, reduceMotion: reduceMotion)
    }

    private func otherSection(_ other: OtherAgent) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text("Hand Off to \(other.agent.title)").font(.headline)
            .padding(.horizontal, Space.m * 2)
            .padding(.top, Space.l)
            .padding(.bottom, Space.xs)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: Space.xxs) {
                ForEach(other.models, id: \.id) { option in
                    row(option, selected: other.modelID == option.id, effort: other.$effort, canChange: true, canChangeEffort: true) {
                        pickOther(option, in: other)
                    }
                }
                if other.accounts.count > 1 {
                    Picker(selection: other.$accountID) {
                        Text("Auto").tag(String?.none)
                        ForEach(other.accounts) { Text($0.name).tag(Optional($0.id)) }
                    } label: {
                        Text("Account")
                    }
                    .pickerStyle(.menu)
                    .frame(minHeight: 44)
                    .padding(.horizontal, Space.m)
                }
            }
            .padding(.horizontal, Space.m)
        }
    }

    private func modeSection(_ mode: ModeRow) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Mode").font(.headline)
                .padding(.horizontal, Space.m)
                .accessibilityAddTraits(.isHeader)
            Picker("Mode", selection: Binding(get: { pickedMode ?? mode.current }, set: { apply == nil ? mode.set($0) : (pickedMode = $0) })) {
                ForEach(mode.offered, id: \.self) { Text($0.brief).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(mode.busy)
        }
        .padding(.horizontal, Space.m)
        .padding(.top, Space.l)
        .sensoryFeedback(.selection, trigger: pickedMode ?? mode.current)
    }

    private func pickOther(_ option: ModelOption, in other: OtherAgent) {
        guard other.modelID != option.id else { return }
        withAnimation(Motion.snappy(reduceMotion)) {
            other.modelID = option.id
            if let effort = other.effort, !option.efforts.contains(effort) { other.effort = nil }
            if option.efforts.count < 2 { showsStops = false }
        }
    }

    private func row(_ option: ModelOption, selected: Bool, effort: Binding<Effort?>, canChange: Bool, canChangeEffort: Bool,
                     pick: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Button(action: pick) {
                    Text(option.title)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!canChange && !selected)
                .accessibilityAddTraits(selected ? .isSelected : [])
                if selected, let shown = effort.wrappedValue ?? option.defaultEffort ?? option.efforts.first {
                    if option.efforts.count > 1 {
                        Button {
                            withAnimation(Motion.smooth(reduceMotion)) { showsStops.toggle() }
                        } label: {
                            HStack(spacing: Space.xxs) {
                                Text(shown.title).contentTransition(.opacity)
                                Image(systemName: "chevron.forward")
                                    .font(.footnote.weight(.semibold))
                                    .rotationEffect(.degrees(showsStops ? 90 : 0))
                            }
                            .foregroundStyle(.secondary)
                            .hitArea(horizontal: Space.xs, vertical: Space.xs)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Effort, \(shown.title)")
                        .accessibilityHint(showsStops ? "Hides the effort stops" : "Shows the effort stops")
                    } else {
                        Text(shown.title).foregroundStyle(.secondary)
                    }
                }
            }
            if selected, showsStops, option.efforts.count > 1 {
                EffortStops(efforts: option.efforts, recommended: option.defaultEffort, effort: effort)
                    .disabled(!canChangeEffort)
                    .padding(.bottom, Space.s)
                    .id("stops")
                    .transition(.opacity)
            }
        }
        .focusRow(selected: selected, in: focus, reduceMotion: reduceMotion)
    }

    private func pick(_ id: String?) {
        if let other, other.modelID != nil {
            withAnimation(Motion.snappy(reduceMotion)) { other.modelID = nil }
        }
        guard id != modelID else { return }
        withAnimation(Motion.snappy(reduceMotion)) {
            modelID = id
            if let effort, chosen?.efforts.contains(effort) != true { self.effort = nil }
            if (chosen?.efforts.count ?? 0) < 2 { showsStops = false }
        }
    }
}

extension View {
    fileprivate func focusRow(selected: Bool, in namespace: Namespace.ID, reduceMotion: Bool) -> some View {
        padding(.horizontal, Space.m)
            .background {
                if selected {
                    let fill = RoundedRectangle(cornerRadius: Radius.questionCard, style: .continuous).fill(Color(.tertiarySystemFill))
                    if reduceMotion {
                        fill.transition(.opacity)
                    } else {
                        fill.matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
            }
            .opacity(selected ? 1 : 0.45)
            .scaleEffect(selected || reduceMotion ? 1 : 0.96, anchor: .leading)
    }
}

private struct EffortStops: View {
    let efforts: [Effort]
    let recommended: Effort?
    @Binding var effort: Effort?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var index: Int {
        (effort ?? recommended).flatMap(efforts.firstIndex(of:)) ?? efforts.count / 2
    }

    var body: some View {
        let shown = efforts[index]
        VStack(spacing: Space.s) {
            VStack(spacing: 1) {
                Text("Recommended")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tint)
                    .opacity(shown == recommended ? 1 : 0)
                ZStack {
                    Text(shown.title)
                        .font(.headline)
                        .id(shown)
                        .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
                }
            }
            .animation(Motion.snappy(reduceMotion), value: shown)
            .accessibilityHidden(true)
            EffortTrack(count: efforts.count, index: index) { stop in
                if efforts[stop] != shown || effort == nil { effort = efforts[stop] }
            }
            .accessibilityElement()
            .accessibilityLabel("Effort")
            .accessibilityValue(shown.title + (shown == recommended ? ", recommended" : ""))
            .accessibilityAdjustableAction { direction in
                let next = direction == .increment ? index + 1 : index - 1
                guard efforts.indices.contains(next) else { return }
                withAnimation(Motion.settle(reduceMotion)) { effort = efforts[next] }
            }
            Text(shown == .auto ? "Auto lets the model decide how long to think on each step."
                 : "Higher effort is more thorough, but slower, and uses your limits faster.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, Space.xs)
        .sensoryFeedback(.selection, trigger: index)
    }
}

private struct EffortTrack: View {
    let count: Int
    let index: Int
    let choose: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var scaled: CGFloat = 44

    @State private var end: CGFloat?
    @State private var grab: CGFloat = 0
    @State private var touchedAt = Date.distantPast

    private var height: CGFloat { min(max(scaled, 44), 60) }

    var body: some View {
        GeometryReader { proxy in
            let stops = (0..<count).map { stop($0, width: proxy.size.width) }
            let resting = stops[index] + height / 2
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                dots(stops, color: Color(.tertiaryLabel))
                thumb(stops, end: reduceMotion ? resting : end ?? resting)
                    .id(reduceMotion ? index : -1)
                    .transition(.opacity)
            }
            // Not `.animation(_:value:)`: its nil would strip the settle spring off a release.
            .transaction(value: index) { if reduceMotion { $0.animation = .easeOut(duration: 0.2) } }
            .contentShape(.capsule)
            .gesture(drag(stops), isEnabled: isEnabled)
        }
        .frame(height: height)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func thumb(_ stops: [CGFloat], end: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color(.label)).frame(width: max(end, height * 0.8))
            dots(stops, color: Color(.systemBackground))
                .mask(alignment: .leading) { Capsule().frame(width: max(end, height * 0.8)) }
        }
        .compositingGroup()
    }

    private func dots(_ stops: [CGFloat], color: Color) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(stops.indices, id: \.self) { stop in
                Circle().fill(color).frame(width: 6, height: 6).position(x: stops[stop], y: height / 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stop(_ index: Int, width: CGFloat) -> CGFloat {
        count > 1 ? height / 2 + CGFloat(index) * (width - height) / CGFloat(count - 1) : width / 2
    }

    private func nearest(_ end: CGFloat, _ stops: [CGFloat]) -> Int {
        stops.indices.min { abs(stops[$0] + height / 2 - end) < abs(stops[$1] + height / 2 - end) } ?? index
    }

    private func drag(_ stops: [CGFloat]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let low = stops[0] + height / 2, high = stops[stops.count - 1] + height / 2
                if end == nil {
                    touchedAt = .now
                    grab = (stops[index] + height / 2) - value.startLocation.x
                }
                guard abs(value.translation.width) > 2 || end != nil else { return }
                var next = value.location.x + grab
                if next > high { next = high + min((next - high) * 0.25, 8) }
                if next < low { next = low - min((low - next) * 0.25, 8) }
                if Date.now.timeIntervalSince(touchedAt) < 0.15 {
                    withAnimation(.interactiveSpring(duration: 0.15)) { end = next }
                } else {
                    var plain = Transaction()
                    plain.disablesAnimations = true
                    withTransaction(plain) { end = next }
                }
                let crossed = nearest(next, stops)
                if crossed != index { choose(crossed) }
            }
            .onEnded { value in
                guard let from = end else {
                    let tapped = stops.indices.min { abs(stops[$0] - value.location.x) < abs(stops[$1] - value.location.x) } ?? index
                    withAnimation(Motion.settle(reduceMotion)) { choose(tapped) }
                    return
                }
                let velocity = value.velocity.width
                let target = nearest(from + velocity * 0.06, stops)
                let distance = stops[target] + height / 2 - from
                let fraction = abs(distance) > 0.5 ? min(max(velocity / distance, -20), 20) : 0
                withAnimation(Motion.settle(reduceMotion, velocity: fraction)) {
                    end = nil
                    choose(target)
                }
            }
    }
}

extension PermissionMode {
    /// One word, to fit a segment.
    var brief: String {
        switch self {
        case .default: "Ask"
        case .acceptEdits: "Edits"
        case .bypassPermissions: "Bypass"
        default: title
        }
    }
}

extension ModelOption {
    static func chipText(_ model: ModelOption?, effort: Effort?) -> String {
        guard let model else { return "Default model" }
        let shown = (effort ?? model.defaultEffort).flatMap { $0 == .auto ? nil : $0.title }
        return [model.title, shown].compactMap { $0 }.joined(separator: " · ")
    }
}
