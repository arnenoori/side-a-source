import Observation
import SideAProtocol
import SideARemoteShared
import SwiftUI

/// What the card shows and where its answer stands. A question pages through its set compactly; a
/// single question answers on the tap.
@Observable
final class NotificationCardModel {
    nonisolated deinit {}

    enum Sending: Equatable { case idle, sending, sent, answeredElsewhere, queued(String), failed(String) }

    let category: String
    let payload: PushPayload?
    let title: String
    let subtitle: String
    let body: String
    private(set) var page = 0
    private(set) var picked: [Int: Set<String>] = [:]
    private(set) var sending = Sending.idle
    private var typedText: [Int: String] = [:]

    @ObservationIgnored var onWriteOwn: () -> Void = {}
    @ObservationIgnored var onOpen: () -> Void = {}
    @ObservationIgnored var onSent: () -> Void = {}
    @ObservationIgnored var onHeight: (CGFloat) -> Void = { _ in }

    init(category: String, payload: PushPayload?) {
        self.category = category
        self.payload = payload
        let words = payload.map(PushOpener.words)
        title = words?.title ?? "Side A"
        subtitle = words?.subtitle ?? ""
        body = words?.body ?? ""
    }

    var questions: [IslandQuestion] { payload?.full == false ? [] : payload?.questions ?? [] }
    var question: IslandQuestion? { questions.indices.contains(page) ? questions[page] : nil }

    func tap(_ option: IslandQuestion.Option) {
        guard let question, sending == .idle || sending.isRetryable else { return }
        if question.multiSelect {
            picked[page, default: []].formSymmetricDifference([option.label])
        } else {
            picked[page] = [option.label]
            advance()
        }
    }

    /// Multi-select's Continue, or the typed answer from the text action.
    func advance() {
        if page + 1 < questions.count {
            page += 1
        } else {
            send(.answers(questions.indices.map { index in
                let options = questions[index].options.map(\.label).filter { picked[index]?.contains($0) == true }
                return QuestionAnswer(question: questions[index].question, picked: options, other: typedText[index])
            }))
        }
    }

    func back() {
        guard page > 0, sending == .idle else { return }
        page -= 1
    }

    func typed(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typedText[page] = text
        if question?.multiSelect == false { picked[page] = [] }
        advance()
    }

    func send(_ answer: RemoteAnswer) {
        guard let payload, let request = payload.rid, sending == .idle || sending.isRetryable else { return }
        sending = .sending
        Task {
            // Expanded from a locked Lock Screen: the owner first, as the Allow button's unlock would ask.
            if DeviceLock.isLocked, !(await OwnerAuth.confirm(reason: "Answer \(payload.title ?? "the question")")) {
                sending = .failed("Unlock your iPhone to answer.")
                return
            }
            let result = await NotificationAnswer.send(answer, to: request, macID: payload.mac)
            switch result {
            case .sent: sending = .sent
            case .answeredElsewhere: sending = .answeredElsewhere
            case .queued(let mac): sending = .queued(mac)
            case .failed(let message): sending = .failed(message)
            case .noMac: sending = .failed("This iPhone isn't paired with that Mac any more.")
            }
            if case .sent = sending { onSent() }
        }
    }
}

extension NotificationCardModel.Sending {
    var isRetryable: Bool { if case .failed = self { true } else { false } }
}

/// The card: the notification's own title and subtitle, then the category's body. The system's
/// default content is hidden, so this is the whole view above the actions.
struct NotificationCard: View {
    let card: NotificationCardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.headline)
                if !card.subtitle.isEmpty {
                    Text(card.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { card.onHeight($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .smooth, value: card.page)
        .animation(reduceMotion ? nil : .smooth, value: card.sending)
        // The app's cap: past xxLarge the card's rows break apart.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .tint(Accent.current.color)
    }

    @ViewBuilder private var content: some View {
        switch card.sending {
        case .sent:
            Outcome(symbol: "checkmark.circle.fill", tint: .green, line: "Sent")
        case .answeredElsewhere:
            Outcome(symbol: "checkmark.circle", tint: .secondary, line: "Answered on the Mac")
        case .queued(let mac):
            Outcome(symbol: "clock", tint: .secondary, line: "Couldn't reach \(mac). Side A Remote will send it when it can.")
        default:
            switch card.payload == nil ? "" : card.category {
            case "": OpenToAnswer(line: "Open Side A Remote", open: card.onOpen)
            case "QUESTION": QuestionBody(card: card)
            case "PLAN": PlanBody(card: card)
            default: RequestBody(card: card)
            }
            if case .failed(let message) = card.sending {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct Outcome: View {
    let symbol: String
    let tint: Color
    let line: String

    var body: some View {
        Label {
            Text(line).font(.body.weight(.medium))
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint).symbolEffect(.bounce, value: line)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
    }
}

/// "Open to answer", for a set that didn't fit in the push: never partial options.
private struct OpenToAnswer: View {
    let line: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack {
                Text(line)
                Spacer()
                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Question

private struct QuestionBody: View {
    let card: NotificationCardModel

    var body: some View {
        if let question = card.question {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    header(question)
                    Text(question.question).font(.headline).fixedSize(horizontal: false, vertical: true)
                }
                .id(card.page)
                .transition(.push(from: .trailing))
                rows(question)
                if question.multiSelect {
                    let count = card.picked[card.page]?.count ?? 0
                    Button {
                        card.advance()
                    } label: {
                        Text(card.page + 1 < card.questions.count ? "Continue" : "Send")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(count == 0 || (card.sending != .idle && !card.sending.isRetryable))
                }
            }
        } else {
            OpenToAnswer(line: "Open to answer", open: card.onOpen)
        }
    }

    @ViewBuilder private func header(_ question: IslandQuestion) -> some View {
        HStack(spacing: 6) {
            if card.page > 0 {
                Button("Back", systemImage: "chevron.backward", action: card.back)
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.semibold))
                    .accessibilityLabel("Previous question")
            }
            if card.questions.count > 1 {
                Text("Question \(card.page + 1) of \(card.questions.count)").monospacedDigit()
            } else if let header = question.header {
                Text(header)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func rows(_ question: IslandQuestion) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(question.options.enumerated()), id: \.element.label) { index, option in
                OptionRow(number: index + 1, option: option, multiSelect: question.multiSelect,
                          picked: card.picked[card.page]?.contains(option.label) == true,
                          sending: card.sending == .sending && card.picked[card.page]?.contains(option.label) == true) {
                    card.tap(option)
                }
                Divider().padding(.leading, 48)
            }
            Button(action: card.onWriteOwn) {
                HStack(spacing: 12) {
                    Image(systemName: "pencil").frame(width: 20).foregroundStyle(.secondary)
                    Text("Write your own…")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12, style: .continuous))
        .disabled(card.sending != .idle && !card.sending.isRetryable)
        .id(card.page)
        .transition(.push(from: .trailing))
        .sensoryFeedback(.selection, trigger: card.picked)
    }
}

private struct OptionRow: View {
    let number: Int
    let option: IslandQuestion.Option
    let multiSelect: Bool
    let picked: Bool
    let sending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(number)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(option.title)
                        if option.recommended {
                            Text("Recommended").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                    if let description = option.description, !description.isEmpty {
                        Text(description).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if sending {
                    ProgressView().controlSize(.small)
                } else if picked || multiSelect {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 48)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

// MARK: - Plan

private struct PlanBody: View {
    let card: NotificationCardModel
    @State private var height: CGFloat = 0

    var body: some View {
        if let plan = card.payload?.plan, card.payload?.full != false {
            ScrollView {
                PlanMarkdown(blocks: MarkdownParser.blocks(RequestText.visible(plan)))
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(height, 1), 400))
            .padding(12)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12, style: .continuous))
        } else {
            OpenToAnswer(line: "Open to review the plan", open: card.onOpen)
        }
    }
}

/// The transcript's Markdown, compact and without images: the blocks from the shared parser, with
/// inline code brought down to the smaller text.
private struct PlanMarkdown: View {
    let blocks: [MarkdownBlock]

    init(blocks: [MarkdownBlock]) {
        self.blocks = blocks.map { block in
            var text = block.text
            for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
                text[run.range].font = .footnote.monospaced()
            }
            return MarkdownBlock(id: block.id, kind: block.kind, text: text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block.kind {
                case .paragraph:
                    Text(block.text).font(.subheadline)
                case .heading(let level):
                    Text(block.text).font(level <= 2 ? .headline : .subheadline.weight(.semibold)).padding(.top, level <= 2 ? 4 : 0)
                case .code:
                    Text(String(block.text.characters).trimmingCharacters(in: .newlines))
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8, style: .continuous))
                case .listItem(let marker, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
                        Text(block.text)
                    }
                    .font(.subheadline)
                    .padding(.leading, CGFloat(depth - 1) * 16)
                case .quote:
                    Text(block.text).font(.subheadline).foregroundStyle(.secondary)
                case .rule:
                    Divider()
                case .table(let header, let rows):
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow { ForEach(header.indices, id: \.self) { Text(header[$0]).fontWeight(.semibold) } }
                        ForEach(rows.indices, id: \.self) { row in
                            GridRow { ForEach(rows[row].indices, id: \.self) { Text(rows[row][$0]) } }
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Request

private struct RequestBody: View {
    let card: NotificationCardModel
    @State private var height: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !card.body.isEmpty {
                // All of it, as the plan: the Allow under the card is for this command, so none of it is cut; a long
                // one scrolls.
                ScrollView {
                    Text(card.body)
                        .font(.callout.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(max(height, 1), 400))
                .padding(12)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12, style: .continuous))
            }
            if card.payload?.risk == .destructive || card.category == "REQUEST_DESTRUCTIVE" {
                Label {
                    Text(RequestText.visible(["Destructive", card.payload?.riskReason].compactMap(\.self).joined(separator: " · ")))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.red)
                if card.category == "REQUEST_DESTRUCTIVE" {
                    Text("Allow only in the app, after Face ID.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}
