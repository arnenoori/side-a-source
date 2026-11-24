import SideAProtocol
import SwiftUI

struct DictationButton: View {
    let dictation: Dictation

    var body: some View {
        Button { Task { await dictation.begin() } } label: {
            Image(systemName: "mic")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .contentShape(.circle)
                .hitArea(horizontal: 4, vertical: 4)
                .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dictate")
    }
}

struct DictationBar: View {
    let dictation: Dictation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var confirmsDiscard = false

    var body: some View {
        HStack(spacing: Space.xs) {
            round("xmark", label: leadingLabel, prominent: false) { dictation.asksToDiscard ? (confirmsDiscard = true) : dictation.cancel() }
                .confirmationDialog("Discard recording?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                    Button("Discard", role: .destructive) { dictation.cancel() }
                    Button("Keep", role: .cancel) {}
                }
            middle
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(minHeight: 48)
        .animation(Motion.snappy(reduceMotion), value: dictation.phase)
    }

    private var leadingLabel: String {
        switch dictation.phase {
        case .failed: dictation.canRetry ? "Discard recording" : "Close"
        case .denied: "Close"
        default: "Cancel dictation"
        }
    }

    @ViewBuilder private var middle: some View {
        switch dictation.phase {
        case .recording:
            HStack(spacing: Space.xs) {
                if reduceMotion { LevelMeter(level: dictation.levels.last ?? 0) } else { Waveform(levels: dictation.levels) }
                clock
            }
        case .transcribing:
            HStack(spacing: Space.xs) {
                ProgressView().controlSize(.small)
                Text("Transcribing…")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .denied:
            Text("Side A can't use the microphone. Turn it on in Settings.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch dictation.phase {
        case .recording:
            round("checkmark", label: "Stop and transcribe", prominent: true) { dictation.finish() }
        case .failed where dictation.canRetry:
            Button("Retry") { dictation.retry() }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
                .frame(minWidth: 44, minHeight: 44)
        case .denied:
            Button("Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
                .frame(minWidth: 44, minHeight: 44)
        default:
            EmptyView()
        }
    }

    private var clock: some View {
        let left = Dictation.limit - dictation.elapsed
        let closing = left <= Dictation.closing
        let shown = Duration.seconds(closing ? max(left, 0) : dictation.elapsed).formatted(.time(pattern: .minuteSecond))
        return Text(closing ? "\(shown) left" : shown)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(closing ? AnyShapeStyle(Color.amberText) : AnyShapeStyle(.secondary))
            .accessibilityLabel(closing ? "Recording, \(shown) left of \(Int(TranscribeRoute.longest / 60)) minutes" : "Recording, \(shown)")
    }

    private func round(_ symbol: String, label: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(prominent ? Color(.systemBackground) : .primary)
                .frame(width: 36, height: 36)
                .background { Circle().fill(prominent ? Color(.label) : Color(.tertiarySystemFill)) }
                .compositingGroup()
                .hitArea(horizontal: 4, vertical: 4)
                .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct Waveform: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            let step = size.width / CGFloat(max(levels.count, 1))
            let width = max(2, step * 0.55)
            for (index, level) in levels.enumerated() {
                let height = max(3, CGFloat(level) * size.height)
                let bar = CGRect(x: CGFloat(index) * step + (step - width) / 2, y: (size.height - height) / 2, width: width, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: width / 2), with: .color(.primary.opacity(0.75)))
            }
        }
        .frame(height: 28)
        .accessibilityHidden(true)
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(.secondary).frame(width: max(6, proxy.size.width * CGFloat(level)))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
    }
}

struct DictationNote: View {
    let dictation: Dictation

    var body: some View {
        if let note = dictation.note {
            Label(note, systemImage: "waveform")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.xs)
                .transition(.opacity)
        }
    }
}

extension View {
    /// The view stays, hidden, so the text view keeps its caret and undo.
    func dictating(_ dictation: Dictation) -> some View { modifier(Dictating(dictation: dictation)) }

    func dictation(_ dictation: Dictation, text: Binding<String>, selection: Binding<NSRange>, focused: Binding<Bool>,
                   session: RemoteSession?, project: String? = nil, shelf: String? = nil) -> some View {
        modifier(DictationLink(dictation: dictation, text: text, selection: selection, focused: focused, session: session, project: project,
                               shelf: shelf))
    }
}

private struct Dictating: ViewModifier {
    let dictation: Dictation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let active = dictation.isActive
        ZStack {
            content
                .opacity(active ? 0 : 1)
                .allowsHitTesting(!active)
                .accessibilityHidden(active)
                .frame(maxHeight: active ? 0 : nil, alignment: .top)
            if active {
                DictationBar(dictation: dictation)
                    .transition(.opacity)
            }
        }
        .animation(Motion.snappy(reduceMotion), value: active)
    }
}

private struct DictationLink: ViewModifier {
    let dictation: Dictation
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var focused: Bool
    let session: RemoteSession?
    let project: String?
    let shelf: String?
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onAppear(perform: link)
            .onChange(of: session?.id) { link() }
            .onChange(of: project) { link() }
            .onChange(of: shelf) { link() }
            .onChange(of: ObjectIdentifier(model)) { link() }
            .onChange(of: DictationShelf.shared.keys) { dictation.adopt() }
            .onDisappear { dictation.leave() }
            .sensoryFeedback(.start, trigger: dictation.starts)
            .sensoryFeedback(.stop, trigger: dictation.stops)
            .sensoryFeedback(.error, trigger: dictation.failures)
            .animation(Motion.smooth(reduceMotion), value: dictation.note)
    }

    private func link() {
        dictation.target = Dictation.Target(text: $text, selection: $selection, focused: $focused, model: model, session: session, project: project,
                                            shelf: shelf)
        dictation.adopt()
    }
}

struct PromptDictation: View {
    let dictation: Dictation
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var focused: Bool
    let model: AppModel
    let project: String?
    let shelf: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: Space.xs) {
            if dictation.isActive {
                DictationBar(dictation: dictation)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24, style: .continuous))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            } else {
                DictationButton(dictation: dictation)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            DictationNote(dictation: dictation)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(Motion.snappy(reduceMotion), value: dictation.isActive)
        .dictation(dictation, text: $text, selection: $selection, focused: $focused, session: nil, project: project, shelf: shelf)
        .environment(model)
    }
}
