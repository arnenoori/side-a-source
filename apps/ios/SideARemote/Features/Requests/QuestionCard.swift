import SideAProtocol
import SwiftUI

/// Claude's `AskUserQuestion`, inline in the transcript: one question at a time,
/// lettered options, answered questions folded into summary lines above the current one.
struct QuestionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: RemoteRequest
    /// Typed text in the composer: the current question's "write your own" answer.
    var typed: String = ""
    var focusComposer: () -> Void = {}

    @State private var index = 0
    @State private var picks: [Int: [String]] = [:]
    @State private var forward = true
    @State private var selections = 0
    /// The pick that will advance after 250 ms; cancelled by another tap.
    @State private var pendingAdvance: Int?

    private var questions: [IslandQuestion] {
        if case .question(let questions) = request.action { questions } else { [] }
    }

    private var single: Bool { questions.count == 1 && questions.first?.multiSelect == false }
    private var finished: Bool { index >= questions.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(questions.enumerated()).filter { $0.offset < index }, id: \.offset) { offset, question in
                Button {
                    go(to: offset)
                } label: {
                    Label {
                        Text("\(question.header ?? "Question") · \(summary(offset))").lineLimit(3)
                    } icon: {
                        Image(systemName: "checkmark").foregroundStyle(Color.done)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Changes this answer")
            }

            ZStack(alignment: .topLeading) {
                if finished {
                    sendSection.transition(transition)
                } else {
                    page(questions[index]).id(index).transition(transition)
                }
            }
        }
        .padding(Space.m)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Radius.questionCard, style: .continuous))
        .sensoryFeedback(.selection, trigger: selections)
        .onAppear(perform: preselect)
        .task(id: pendingAdvance) {
            guard let pending = pendingAdvance else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, pendingAdvance == pending else { return }
            pendingAdvance = nil
            if single { send() } else { advance() }
        }
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .push(from: forward ? .trailing : .leading)
    }

    @ViewBuilder private func page(_ question: IslandQuestion) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                if let header = question.header {
                    Text(header).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if questions.count > 1 {
                    Text("\(index + 1) of \(questions.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            Text(question.question)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { offset, option in
                    OptionRow(letter: String(UnicodeScalar(UInt8(65 + offset))), option: option,
                              picked: picks[index, default: []].contains(option.label)) {
                        pick(option.label, in: question)
                    }
                    Divider().padding(.leading, 52)
                }
                OptionRow(letter: nil, option: IslandQuestion.Option(label: "Write your own…", description: nil),
                          picked: false, action: focusComposer)
            }
            .background(Color(.systemBackground))
            .clipShape(.rect(cornerRadius: Radius.inlineCard, style: .continuous))

            if question.multiSelect {
                Button {
                    advance()
                } label: {
                    Text("Next").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(picks[index, default: []].isEmpty && typed.isEmpty)
            }
        }
    }

    private var sendSection: some View {
        Button {
            send()
        } label: {
            Text("Send Answers").fontWeight(.semibold).frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(.amber)
        .controlSize(.large)
        .needsMac()
        .padding(.top, Space.xs)
    }

    /// Starts each single-choice question on Claude's recommended answer, as the Mac does.
    private func preselect() {
        for (offset, question) in questions.enumerated() where !question.multiSelect && picks[offset] == nil {
            if let option = question.options.first(where: \.recommended) { picks[offset] = [option.label] }
        }
    }

    private func pick(_ label: String, in question: IslandQuestion) {
        selections += 1
        if question.multiSelect {
            var current = picks[index, default: []]
            if let at = current.firstIndex(of: label) { current.remove(at: at) } else { current.append(label) }
            picks[index] = current
        } else {
            picks[index] = [label]
            pendingAdvance = (pendingAdvance ?? 0) + 1
        }
    }

    private func advance() {
        forward = true
        withAnimation(Motion.smooth(reduceMotion)) { index += 1 }
    }

    private func go(to offset: Int) {
        pendingAdvance = nil
        forward = false
        withAnimation(Motion.smooth(reduceMotion)) { index = offset }
    }

    private func summary(_ offset: Int) -> String {
        picks[offset, default: []].map(IslandQuestion.Option.titleOf).joined(separator: ", ")
    }

    private func send() {
        let answers = questions.enumerated().map { offset, question in
            QuestionAnswer(question: question.question, picked: picks[offset, default: []], other: nil)
        }
        withAnimation(Motion.smooth(reduceMotion)) {
            model.requests.answer(request.id, .answers(answers))
        }
    }
}

/// A lettered option: badge, label, description under it; "(Recommended)" as a quiet suffix.
private struct OptionRow: View {
    let letter: String?
    let option: IslandQuestion.Option
    let picked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Group {
                    if let letter {
                        Text(letter).font(.subheadline.monospaced())
                    } else {
                        Image(systemName: "pencil").font(.footnote)
                    }
                }
                .foregroundStyle(.tertiary)
                .frame(width: 24, height: 24)
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: Radius.letterBadge, style: .continuous))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }

                VStack(alignment: .leading, spacing: 2) {
                    (Text(option.title) + (option.recommended ? Text("  Recommended").font(.caption).foregroundStyle(.secondary) : Text("")))
                        .font(.body)
                        .foregroundStyle(letter == nil ? .secondary : .primary)
                    if let description = option.description {
                        Text(description).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if picked {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.amberText)
                        .transition(.symbolEffect(.automatic))
                }
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .contentShape(.rect)
        }
        .buttonStyle(Pressed())
        .accessibilityLabel([letter, option.title, option.recommended ? "recommended" : nil, option.description].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// A row's highlight while a finger is on it: on at once, fading out once it lifts.
private struct Pressed: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color(.systemFill).opacity(configuration.isPressed ? 1 : 0))
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.2), value: configuration.isPressed)
    }
}
