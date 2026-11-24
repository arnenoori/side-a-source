import SideAProtocol
import SideARemoteShared
import SwiftUI

struct TurnFold: Hashable, Identifiable {
    let id: String
    let items: [TranscriptItem]
    let started: Date?
    let duration: TimeInterval?
    let live: Bool

    func holds(message seq: Int) -> Bool {
        items.contains { if case .assistant(let message) = $0 { message.seq == seq } else { false } }
    }
}

extension TranscriptLayout {
    static func folded(_ items: [TranscriptItem], working: Bool, since: Date?) -> [TranscriptItem] {
        var result: [TranscriptItem] = []
        var segment: [TranscriptItem] = []
        var opener: TranscriptItem?

        func flush(last: Bool) {
            defer { segment = [] }
            let ended = segment.contains { if case .turnEnd = $0 { true } else { false } }
            let live = last && working && !ended
            guard opener != nil || live || segment.contains(where: \.isStep) else { result += segment; return }
            var answer = segment.lastIndex { if case .assistant = $0 { true } else { false } }
            if live, let index = answer, segment[(index + 1)...].contains(where: \.isStep) { answer = nil }
            let work = segment.enumerated().filter { $0.offset != answer && $0.element.folds }.map(\.element)
            guard live || !work.isEmpty else { result += segment; return }
            var worked: TimeInterval?
            for case .turnEnd(let end) in segment { worked = end.duration }
            let start = opener?.sentAt ?? (live ? since : nil)
            result.append(.turn(TurnFold(id: "fold-\(work.first?.id ?? opener?.id ?? "live")", items: work, started: start,
                                         duration: live ? nil : worked, live: live)))
            if let answer { result.append(segment[answer]) }
            for item in segment where !item.folds {
                if case .turnEnd(let end) = item, worked != nil {
                    result.append(.turnEnd(TurnEnd(seq: end.seq, model: end.model, duration: nil, message: end.message)))
                } else {
                    result.append(item)
                }
            }
        }

        for item in items {
            switch item {
            case .user, .outgoing:
                flush(last: false)
                result.append(item)
                opener = item
            case .earlier, .separator:
                flush(last: false)
                result.append(item)
            default:
                segment.append(item)
            }
        }
        flush(last: true)
        return result
    }
}

private extension TranscriptItem {
    var isStep: Bool {
        switch self {
        case .tool, .subagent, .thinking, .group, .diff, .file, .images: true
        default: false
        }
    }

    var folds: Bool { if case .assistant = self { true } else { isStep } }

    var sentAt: Date? {
        switch self {
        case .user(let message): message.at.map(Date.init(timeIntervalSince1970:))
        case .outgoing(let turn): turn.at
        default: nil
        }
    }
}

struct TurnFoldRow<Step: View>: View {
    let fold: TurnFold
    let expanded: Bool
    let toggle: () -> Void
    @ViewBuilder var step: (TranscriptItem) -> Step
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Out of reach, the host can't say the turn still runs, so its clock stops at the last word from it.
    private var frozenAt: Date? { model.mac.shown == .live ? nil : model.mac.lastSeen }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if fold.items.isEmpty {
                title.frame(minHeight: 44)
            } else {
                Button {
                    withAnimation(Motion.smooth(reduceMotion)) { toggle() }
                } label: {
                    HStack(spacing: Space.xxs) {
                        title
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "expanded" : "collapsed")
                .accessibilityHint(expanded ? "Hides the steps" : "Shows the steps")
            }
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(fold.items) { item in
                        step(item).padding(.top, item.gapInFold)
                    }
                }
                .transition(.opacity)
            } else if fold.live, let latest = fold.items.last, latest.isStep {
                step(latest)
                    .id(latest.id)
                    .transition(.opacity)
            }
        }
        .animation(Motion.smooth(reduceMotion), value: fold.items.last?.id)
    }

    @ViewBuilder private var title: some View {
        if fold.live, let started = fold.started, frozenAt == nil {
            TimelineView(.periodic(from: started, by: 1)) { context in
                Shimmer(active: !reduceMotion) { line("Working for \(Self.clock(context.date.timeIntervalSince(started)))") }
            }
            .accessibilityLabel("Working")
            .accessibilityAddTraits(.updatesFrequently)
        } else if fold.live {
            line(zip(fold.started, frozenAt).map { "Working for \(Self.clock($1.timeIntervalSince($0)))" } ?? "Working")
        } else {
            line(fold.duration.flatMap { Formatting.duration($0) }.map { "Worked for \($0)" } ?? "Worked")
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        Formatting.duration(max(seconds, 1).rounded(.down)) ?? "1s"
    }

    private func zip(_ a: Date?, _ b: Date?) -> (Date, Date)? {
        guard let a, let b else { return nil }
        return (a, b)
    }
}

private extension TranscriptItem {
    var gapInFold: CGFloat {
        switch self {
        case .tool, .thinking, .group: 0
        default: Space.s
        }
    }
}

private struct Shimmer<Content: View>: View {
    let active: Bool
    @ViewBuilder var content: Content
    @State private var crossed = false

    var body: some View {
        content
            .overlay {
                if active {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, Color(.label), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.6)
                            .offset(x: crossed ? proxy.size.width : -proxy.size.width * 0.6)
                    }
                    .mask { content }
                    .allowsHitTesting(false)
                    .onAppear { withAnimation(Motion.shimmer) { crossed = true } }
                }
            }
    }
}
