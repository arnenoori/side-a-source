import SideACore
import SideAProtocol
import SwiftUI

/// Answers the same hook connections the island holds, so whichever answers first wins.
struct SessionActions: View {
    let model: SessionStore
    let sessionID: String
    private var island: Island { model.store.island }

    var body: some View {
        let request = island.pending.first { $0.request.sessionID == sessionID }
        let target = ComposerTarget(sessionID, store: model.store)
        let plan = target.live.flatMap { WireBuilders.session($0, store: model.store, finished: []).plan }
        VStack(spacing: 0) {
            if let plan, !plan.steps.isEmpty {
                PlanCard(plan: plan).padding(.horizontal, 14).padding(.bottom, 8)
                    .transition(.opacity)
            }
            if let request {
                Rectangle().fill(Ink.line).frame(height: 1)
                RequestPanel(island: island, item: request).id(request.id)
                    .transition(Ink.rise(8))
            } else if target.canReply {
                Rectangle().fill(Ink.line).frame(height: 1)
                SessionComposer(model: model, target: target).id(sessionID)
                    .transition(Ink.rise(8))
            }
        }
        .animation(Ink.ease, value: request?.id)
        .animation(Ink.ease, value: target.canReply)
        .animation(Ink.ease, value: plan == nil)
    }
}

private struct RequestPanel: View {
    let island: Island
    let item: Island.Pending
    @State private var revising = false
    @State private var note = ""
    private var request: IslandRequest { item.request }
    private var destructive: Bool { request.risk == .destructive }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Beacon(tint: Ink.amber)
                Text("\(request.agent.title) is waiting for you").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Ink.amber)
                if let reason = request.riskReason, destructive {
                    Label(reason, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                }
                Spacer()
                if let back = item.handBackAt {
                    Text("Back to its prompt \(back, style: .relative)").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Text(request.headline).font(.system(size: 14, weight: .semibold))
            if !request.detail.isEmpty {
                ScrollView {
                    Text(request.detail).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(Ink.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            controls
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(Ink.amber.opacity(0.05))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.agent.title) is waiting for you: \(request.headline)")
    }

    @ViewBuilder private var controls: some View {
        switch request.action {
        case .question(let questions):
            VStack(alignment: .leading, spacing: 10) {
                QuestionsForm(island: island, item: item, questions: questions)
                terminalLink
            }
        case .plan:
            if revising {
                HStack {
                    TextField("What should change?", text: $note).textFieldStyle(.roundedBorder).onSubmit(revise)
                    Button("Send", action: revise).disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { revising = false }
                }
            } else {
                HStack {
                    terminalLink
                    Spacer()
                    Button("Keep Planning…") { revising = true }
                    Button("Accept Edits") { island.answer(.approvePlan(input: request.input, acceptEdits: true), item.id) }
                    Button("Approve") { island.answer(.approvePlan(input: request.input, acceptEdits: false), item.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
        default:
            HStack {
                terminalLink
                Spacer()
                Button("Deny") { island.answer(.deny(nil), item.id) }
                if request.offersAlways, let suggestion = request.suggestions.first {
                    Button(request.agent == .codex ? "This session" : "Always") { island.answer(.always(suggestion), item.id) }.help(suggestion.title)
                }
                // Allow and switch mode, as the phone offers it: Claude's own edits that aren't destructive.
                if RemoteAnswers.modes(request).contains(.acceptEdits) {
                    Button("Allow + Accept Edits") { island.answer(.allowMode(PermissionMode.acceptEdits.rawValue), item.id) }
                        .help("Allow this, and let it make the rest of its edits without asking")
                }
                Button(destructive ? "Allow Anyway" : "Allow") { island.answer(.allow, item.id, confirmed: true) }
                    .buttonStyle(.borderedProminent).tint(destructive ? .red : .accentColor)
            }
        }
    }

    @ViewBuilder private var terminalLink: some View {
        if item.origin == nil {
            Button("Show in Terminal") { island.showTerminal(item) }.buttonStyle(.link).font(.system(size: 12))
        }
    }

    private func revise() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        island.answer(.revisePlan(text), item.id)
    }
}

private struct QuestionsForm: View {
    let island: Island
    let item: Island.Pending
    let questions: [IslandQuestion]
    @State private var answers = QuestionAnswers()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.question).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                        let on = answers.isPicked(option.label, in: question)
                        Button { answers.pick(option.label, in: question) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: question.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                                    .foregroundStyle(on ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(option.title).font(.system(size: 13))
                                        if option.recommended {
                                            Chip(text: "Recommended", tint: .accentColor)
                                        }
                                    }
                                    if let description = QuestionAnswers.description(of: option) {
                                        Text(description).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                    TextField("Something else…", text: Binding(get: { answers.other[question.question] ?? "" }, set: { answers.other[question.question] = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12.5))
                }
            }
            HStack {
                Spacer()
                Button(answers.recommendedOnly(questions) ? "Send Recommended Answers" : "Send Answers", action: send)
                    .buttonStyle(.borderedProminent).disabled(!answers.complete(questions))
            }
        }
        .onAppear { answers.preselect(questions) }
    }

    private func send() {
        guard answers.complete(questions) else { return }
        island.answer(.answers(answers.answers(questions), input: item.request.input), item.id)
    }
}
