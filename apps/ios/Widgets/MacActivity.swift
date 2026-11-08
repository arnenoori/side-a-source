import ActivityKit
import AppIntents
import SideAProtocol
import SideARemoteShared
import SwiftUI
import WidgetKit

/// The Live Activity: counts from the push, words from the phone's own caches. The top
/// request's words come from the Service Extension's decrypted copy; without one it says "1 needs you"
/// and opens the app.
struct MacActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MacActivityAttributes.self) { context in
            LockScreenActivity(state: context.state, stale: context.isStale)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { IslandLeading(state: state).dynamicTypeSize(...DynamicTypeSize.xxLarge) }
                DynamicIslandExpandedRegion(.trailing) { IslandTrailing(state: state).dynamicTypeSize(...DynamicTypeSize.xxLarge) }
                DynamicIslandExpandedRegion(.center) { IslandCenter(state: state).dynamicTypeSize(...DynamicTypeSize.xxLarge) }
                DynamicIslandExpandedRegion(.bottom) { IslandBottom(state: state).dynamicTypeSize(...DynamicTypeSize.xxLarge) }
            } compactLeading: {
                ActivityDisc(waiting: state.waiting > 0)
            } compactTrailing: {
                CompactTrailing(state: state).dynamicTypeSize(...DynamicTypeSize.xxLarge)
            } minimal: {
                MinimalActivity(state: state)
            }
            .widgetURL(ActivityWords(state: state).url)
        }
        .supplementalActivityFamilies([.small])
    }
}

// The island's regions as views of their own, so the debug gallery draws exactly these.

struct IslandLeading: View {
    let state: MacActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            ActivityDisc(waiting: false)
            Text("\(state.working) working")
                .font(.caption.monospacedDigit())
                .contentTransition(.numericText())
        }
        .padding(.leading, 4)
    }
}

struct IslandTrailing: View {
    let state: MacActivityAttributes.ContentState

    var body: some View {
        if let limit = ActivityWords(state: state).limit {
            LimitReadout(limit: limit).padding(.trailing, 4)
        }
    }
}

struct IslandCenter: View {
    let state: MacActivityAttributes.ContentState

    var body: some View {
        if let request = ActivityWords(state: state).request {
            Text(RequestText.visible([request.title, request.subtitle].compactMap { $0 }.joined(separator: " · ")))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        } else if state.waiting > 0 {
            Text("\(state.waiting) needs you").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(activityAmber)
                .contentTransition(.numericText(value: Double(state.waiting)))
        }
    }
}

struct IslandBottom: View {
    let state: MacActivityAttributes.ContentState

    var body: some View {
        if let request = ActivityWords(state: state).request {
            // Allow only under the whole command; one that can't fit here is cut, and Open takes it to the app.
            ViewThatFits(in: .vertical) {
                bottom(request, whole: true)
                bottom(request, whole: false)
            }
            .frame(maxHeight: limit)
        }
    }

    @ScaledMetric(relativeTo: .caption) private var limit: CGFloat = 96

    private func bottom(_ request: PushPayload, whole: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let body = request.body {
                Text(RequestText.visible(body)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(whole ? nil : 2)
                    .fixedSize(horizontal: false, vertical: whole)
            }
            RequestButtons(request: request, requestID: state.topRequest ?? "", openOnly: !whole)
        }
    }
}

struct CompactTrailing: View {
    let state: MacActivityAttributes.ContentState

    var body: some View {
        if state.waiting > 0 {
            Label("\(state.waiting)", systemImage: "hand.raised.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(activityAmber)
                .contentTransition(.numericText(value: Double(state.waiting)))
        } else {
            Text("\(state.working)").font(.caption.monospacedDigit()).contentTransition(.numericText())
        }
    }
}

struct MinimalActivity: View {
    let state: MacActivityAttributes.ContentState

    var body: some View {
        if state.waiting > 0 {
            Circle().fill(activityAmber).frame(width: 8, height: 8)
        } else {
            ActivityDisc(waiting: false)
        }
    }
}

/// What the activity can say about its state, from the push cache and the widget snapshot.
struct ActivityWords {
    let request: PushPayload?
    let limit: WidgetSnapshot.Limit?
    let macName: String?
    let url: URL?

    init(state: MacActivityAttributes.ContentState) {
        let snapshot = WidgetSnapshot.load()
        request = state.topRequest.flatMap(PushCache.load).flatMap { try? JSONDecoder().decode(PushPayload.self, from: $0) }
        limit = snapshot?.tightest
        macName = snapshot?.macName
        // Without the request's words, a tap just opens the app.
        url = request.flatMap { request in request.rid.flatMap { URL(string: "sidea-remote://request/\(request.mac)/\($0)") } }
    }
}

/// Row 1 counts, row 2 the top request with its buttons, row 3 the tightest limit.
struct LockScreenActivity: View {
    let state: MacActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        let words = ActivityWords(state: state)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ActivityDisc(waiting: state.waiting > 0)
                Text("\(Text("\(state.working) working"))\(Text(state.waiting > 0 ? " · \(state.waiting) needs you" : "").foregroundStyle(activityAmber))")
                .font(.headline.monospacedDigit())
                .contentTransition(.numericText())
                Spacer(minLength: 0)
                if stale { Text("Not updated").font(.caption).foregroundStyle(.secondary) }
            }
            if let request = words.request {
                // One row, so the card stays inside the Lock Screen's 160 pt. Allow only beside the whole command;
                // one too long for the row is cut, and Open takes it to the app.
                ViewThatFits(in: .vertical) {
                    requestRow(request, whole: true)
                    requestRow(request, whole: false)
                }
                .frame(maxHeight: rowLimit)
            }
            if let limit = words.limit {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: min(limit.percent, 100), total: 100).tint(limit.percent >= 90 ? .red : limit.percent >= 75 ? .orange : .green)
                    Text("\(limit.account) \(limit.window) \(Int(limit.percent.rounded()))%" + (limit.resetsAt.map { " · resets \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .widgetURL(words.url)
        // A Live Activity has a fixed height; past this, text would push its buttons out.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// The title and up to two lines of command: past that, the card would outgrow the Lock Screen.
    @ScaledMetric(relativeTo: .caption) private var rowLimit: CGFloat = 54

    private func requestRow(_ request: PushPayload, whole: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            RequestWords(request: request, whole: whole)
            Spacer(minLength: 0)
            RequestButtons(request: request, requestID: state.topRequest ?? "", compact: true, openOnly: !whole)
        }
    }
}

private struct RequestWords: View {
    let request: PushPayload
    var whole = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(RequestText.visible(request.title ?? "Needs you")).font(.subheadline.weight(.semibold)).lineLimit(1)
            if let body = request.body {
                Text(RequestText.visible(body)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(whole ? nil : 2)
                    .fixedSize(horizontal: false, vertical: whole)
            }
        }
    }
}

/// Deny, then Allow by the request's gate: runs locked for `lockScreen`, asks to unlock for `unlock`,
/// and for `biometric` becomes Open, which the app answers with Face ID.
private struct RequestButtons: View {
    let request: PushPayload
    let requestID: String
    var compact = false
    /// The words shown are cut, here or by the Mac: Allow waits for the app, where all of it shows.
    var openOnly = false

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: DenyRequestIntent(requestID: requestID, macID: request.mac)) {
                label("Deny")
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            switch openOnly || request.full == false ? nil : request.gate == .lockScreen && !PushOpener.allowsLocked(request) ? .unlock : request.gate {
            case .lockScreen?:
                Button(intent: AllowSafeRequestIntent(requestID: requestID, macID: request.mac)) { prominent("Allow") }
                    .buttonStyle(.borderedProminent)
                    .tint(activityAmber)
            case .unlock?:
                Button(intent: AnswerRequestIntent(requestID: requestID, macID: request.mac)) { prominent("Allow") }
                    .buttonStyle(.borderedProminent)
                    .tint(activityAmber)
            default:
                // A Face ID request is answered in the app; Open looks like the Allow it stands in for.
                Link(destination: URL(string: "sidea-remote://request/\(request.mac)/\(requestID)")!) {
                    prominent("Open")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(activityAmber, in: .capsule)
                }
            }
        }
        .buttonBorderShape(.capsule)
        .font(.subheadline)
    }

    private func label(_ title: String) -> some View {
        Text(title).lineLimit(1).fixedSize().frame(maxWidth: compact ? nil : .infinity)
    }

    /// Amber is light in dark mode and dark in light mode, so its text takes the background's colour.
    private func prominent(_ title: String) -> some View {
        label(title).fontWeight(.semibold).foregroundStyle(Color(.systemBackground))
    }
}

/// "5h 82%" in mono with a 2 pt bar under it.
private struct LimitReadout: View {
    let limit: WidgetSnapshot.Limit

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("\(limit.window) \(Int(limit.percent.rounded()))%").font(.caption.monospacedDigit())
            Capsule().fill(.quaternary).frame(width: 44, height: 2)
                .overlay(alignment: .leading) {
                    Capsule().fill(limit.percent >= 90 ? .red : limit.percent >= 75 ? .orange : .green)
                        .frame(width: 44 * min(limit.percent, 100) / 100, height: 2)
                }
        }
    }
}

/// Side A's amber, from the widgets' own asset catalog (the app compiles this file too).
let activityAmber = Color("AmberText")

/// The disc, drawn static: Live Activity views are snapshots and can't spin. Amber dot when waiting.
struct ActivityDisc: View {
    let waiting: Bool

    var body: some View {
        ZStack {
            // Primary, so it reads on a light Lock Screen as well as the island's black.
            Circle().fill(.primary.opacity(0.3))
            Circle().strokeBorder(.primary.opacity(0.6), lineWidth: 1.2)
            Circle().fill(.primary).frame(width: 6)
        }
        .frame(width: 20, height: 20)
        .overlay(alignment: .topTrailing) {
            if waiting { Circle().fill(activityAmber).frame(width: 6, height: 6).offset(x: 1, y: -1) }
        }
        .accessibilityLabel(waiting ? "Side A, needs you" : "Side A")
    }
}

#Preview("Lock Screen", as: .content, using: MacActivityAttributes(macID: "m")) {
    MacActivityWidget()
} contentStates: {
    MacActivityAttributes.ContentState(working: 3, waiting: 1, topRequest: "r1", tightestPercent: 82)
    MacActivityAttributes.ContentState(working: 2, waiting: 0)
}
