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
                    .transition(.opacity.combined(with: .offset(y: 8)))
            } else if target.canReply {
                Rectangle().fill(Ink.line).frame(height: 1)
                SessionComposer(model: model, target: target).id(sessionID)
                    .transition(.opacity.combined(with: .offset(y: 8)))
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
                WaitingDot()
                Text("\(request.agent.title) is waiting for you").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.orange)
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
        .background(Color.orange.opacity(0.05))
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
                    Button("Revise…") { revising = true }
                    Button("Accept edits") { island.answer(.approvePlan(input: request.input, acceptEdits: true), item.id) }
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
                Button(destructive ? "Allow anyway" : "Allow") { island.answer(.allow, item.id, confirmed: true) }
                    .buttonStyle(.borderedProminent).tint(destructive ? .red : .accentColor)
            }
        }
    }

    @ViewBuilder private var terminalLink: some View {
        if item.origin == nil {
            Button("Show in terminal") { island.showTerminal(item) }.buttonStyle(.link).font(.system(size: 12))
        }
    }

    private func revise() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        island.answer(.deny("The user wants changes to the plan before you start: \(text)"), item.id)
    }
}

private struct QuestionsForm: View {
    let island: Island
    let item: Island.Pending
    let questions: [IslandQuestion]
    @State private var picked: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.question).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                        let on = picked[question.question]?.contains(option.label) == true
                        Button { toggle(question, option.label) } label: {
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
                                    if let description = option.description, !description.isEmpty, description != option.label {
                                        Text(description).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                    TextField("Something else…", text: Binding(get: { other[question.question] ?? "" }, set: { other[question.question] = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12.5))
                }
            }
            HStack {
                Spacer()
                Button(allRecommended ? "Send recommended answers" : "Send answers", action: send)
                    .buttonStyle(.borderedProminent).disabled(!complete)
            }
        }
        .onAppear {
            for question in questions where picked[question.question] == nil {
                if let option = question.options.first(where: \.recommended) { picked[question.question] = [option.label] }
            }
        }
    }

    private func toggle(_ question: IslandQuestion, _ label: String) {
        var chosen = picked[question.question] ?? []
        if question.multiSelect {
            if chosen.contains(label) { chosen.remove(label) } else { chosen.insert(label) }
        } else {
            chosen = [label]
        }
        picked[question.question] = chosen
    }

    private func answer(_ question: IslandQuestion) -> String {
        let typed = (other[question.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = question.options.map(\.label).filter { picked[question.question]?.contains($0) == true }
        return (chosen + (typed.isEmpty ? [] : [typed])).joined(separator: ", ")
    }

    private var complete: Bool { questions.allSatisfy { !answer($0).isEmpty } }

    private var allRecommended: Bool {
        questions.allSatisfy { question in
            let recommended = Set(question.options.filter(\.recommended).map(\.label))
            return !recommended.isEmpty && picked[question.question] == recommended && (other[question.question] ?? "").isEmpty
        }
    }

    private func send() {
        guard complete else { return }
        island.answer(.answers(Dictionary(questions.map { ($0.question, answer($0)) }) { first, _ in first }, input: item.request.input), item.id)
    }
}
