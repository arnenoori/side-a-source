import SideARemoteShared
import SwiftUI
import WidgetKit

/// The tightest limit: the LCD plate on the Home Screen, a gauge and a line on the
/// Lock Screen. Choosing an account arrives with the App Intent configuration.
struct LimitWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Limit", provider: SnapshotProvider()) { entry in
            LimitWidgetView(entry: entry)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
        .configurationDisplayName("Limit")
        .description("The tightest limit on the account in use.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline])
    }
}

struct LimitWidgetView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: SnapshotEntry
    /// The DEBUG gallery's family; WidgetKit's otherwise.
    var familyOverride: WidgetFamily?
    private var family: WidgetFamily { familyOverride ?? widgetFamily }

    var body: some View {
        content
            .widgetURL(URL(string: "sidea-remote://accounts"))
            .containerBackground(for: .widget) {
                // Tinted and clear modes drop the plate for a plain fill.
                if family == .systemSmall && renderingMode == .fullColor { LCDBackground() }
            }
    }

    @ViewBuilder private var content: some View {
        let limit = entry.snapshot?.tightest
        switch family {
        case .accessoryCircular:
            if let limit {
                Gauge(value: limit.percent, in: 0...100) {
                    Text(limit.window)
                } currentValueLabel: {
                    Text("\(Int(limit.percent.rounded()))").monospacedDigit()
                        .contentTransition(.numericText(value: limit.percent))
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .widgetAccentable()
            } else {
                Gauge(value: 0, in: 0...100) { Text("") } currentValueLabel: { Image(systemName: "minus") }
                    .gaugeStyle(.accessoryCircularCapacity)
            }
        case .accessoryInline:
            if let limit {
                Text("\(limit.account) \(limit.window) \(Formatting.percent(limit.percent))"
                     + (limit.resetsAt.map { " · \(Formatting.reset($0, now: entry.date))" } ?? ""))
            } else {
                Text("Side A · no limits yet")
            }
        default:
            if entry.snapshot == nil {
                PairFirst()
            } else if let limit {
                plate(limit)
            } else {
                Text("No limits yet").font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func plate(_ limit: WidgetSnapshot.Limit) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.account).lineLimit(1)
                Spacer(minLength: 4)
                Text(limit.window)
            }
            .font(.caption.monospaced().weight(.semibold))
            .textCase(.uppercase)
            .opacity(0.75)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(Int(limit.percent.rounded()))")
                    .font(.system(size: 50, weight: .semibold, design: .monospaced))
                    .contentTransition(.numericText(value: limit.percent))
                    .widgetAccentable()
                Text("%").font(.system(size: 22, weight: .semibold, design: .monospaced)).opacity(0.75)
            }
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            Spacer(minLength: 0)
            Group {
                if let asOf = entry.asOf {
                    Text(asOf)
                } else if let reset = limit.resetsAt {
                    Text("resets \(Formatting.reset(reset, now: entry.date))")
                }
            }
            .font(.caption2.monospaced().weight(.medium))
            .textCase(.uppercase)
            .opacity(0.75)
        }
        .foregroundStyle(renderingMode == .fullColor ? Color("LCDInk") : .primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limit.account), \(limit.window) limit \(Int(limit.percent.rounded())) percent"
                            + (limit.resetsAt.map { ", resets \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
    }
}

/// The plate's glass: the LCD colour with a faint inner shade at the top, like the app's readout.
private struct LCDBackground: View {
    var body: some View {
        Color("LCDPlate")
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.12), .clear], startPoint: .top, endPoint: .center)
            }
    }
}

#Preview("Small", as: .systemSmall) {
    LimitWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .placeholder)
}

#Preview("Circular", as: .accessoryCircular) {
    LimitWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .placeholder)
}
