import SideAProtocol
import SideASessionKit
import SideARemoteShared
import SwiftUI

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
