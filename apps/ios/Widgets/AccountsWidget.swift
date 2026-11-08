import SideARemoteShared
import SwiftUI
import WidgetKit

/// Up to four accounts as ring pairs: weekly outside, 5-hour inside, the tighter
/// percent under the name.
struct AccountsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Accounts", provider: SnapshotProvider()) { entry in
            AccountsWidgetView(entry: entry)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "sidea-remote://accounts"))
        }
        .configurationDisplayName("Accounts")
        .description("Each account's 5-hour and weekly limits.")
        .supportedFamilies([.systemMedium])
    }
}

struct AccountsWidgetView: View {
    let entry: SnapshotEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            if snapshot.accounts.isEmpty {
                Text("No accounts yet").font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(snapshot.accounts) { account in
                            column(account).frame(maxWidth: .infinity)
                        }
                    }
                    if let asOf = entry.asOf {
                        Text(asOf).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        } else {
            PairFirst()
        }
    }

    private func column(_ account: WidgetSnapshot.Account) -> some View {
        let tightest = [account.fiveHour, account.weekly].compactMap { $0 }.max()
        return VStack(spacing: 6) {
            RingPair(fiveHour: account.fiveHour, weekly: account.weekly)
                .frame(width: 58, height: 58)
            VStack(spacing: 0) {
                Text(account.name)
                    .font(.caption.weight(account.active ? .semibold : .regular))
                    .lineLimit(1)
                Text(tightest.map(Formatting.percent) ?? "–")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(tightest.map(limitColor).map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(account.name)" + (account.active ? ", in use" : "")
                            + (account.fiveHour.map { ", 5-hour \(Int($0.rounded())) percent" } ?? "")
                            + (account.weekly.map { ", weekly \(Int($0.rounded())) percent" } ?? ""))
    }
}

/// Two concentric rings, drawn still: the fills are accentable for tinted and clear modes.
private struct RingPair: View {
    let fiveHour: Double?
    let weekly: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * 0.13
            ZStack {
                ring(weekly, width: width, inset: 0, quiet: true)
                ring(fiveHour, width: width, inset: width + 3, quiet: false)
            }
        }
    }

    private func ring(_ value: Double?, width: CGFloat, inset: CGFloat, quiet: Bool) -> some View {
        let percent = value ?? 0
        return ZStack {
            Circle().stroke(.quaternary, lineWidth: width)
            Circle()
                .trim(from: 0, to: percent / 100)
                .stroke(limitColor(percent).opacity(quiet && percent < 75 ? 0.45 : 1),
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
        }
        .padding(inset + width / 2)
    }
}

#Preview("Accounts", as: .systemMedium) {
    AccountsWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .placeholder)
}
