import SideARemoteShared
import SwiftUI
import WidgetKit

/// What's working and what needs you. Rows open their session; no Allow buttons on
/// the Home Screen, where they're too easy to tap by accident.
struct SessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Sessions", provider: SnapshotProvider()) { entry in
            SessionsWidgetView(entry: entry)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Sessions")
        .description("What's working and what needs you.")
        .supportedFamilies([.systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct SessionsWidgetView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: SnapshotEntry
    /// The DEBUG gallery's family; WidgetKit's otherwise.
    var familyOverride: WidgetFamily?
    private var family: WidgetFamily { familyOverride ?? widgetFamily }

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .accessoryRectangular: rectangular(snapshot)
            case .systemLarge: large(snapshot)
            default: medium(snapshot)
            }
        } else if family == .accessoryRectangular {
            Text("Pair Side A Remote with your Mac").font(.headline).widgetAccentable()
        } else {
            PairFirst()
        }
    }

    // MARK: Home Screen

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(snapshot)
            if snapshot.sessions.isEmpty {
                empty
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.sessions.prefix(3)) { row($0, in: snapshot) }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func large(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(snapshot)
            if snapshot.sessions.isEmpty {
                empty
            } else {
                ForEach([WidgetSnapshot.Session.Phase.needsYou, .working], id: \.self) { phase in
                    let rows = snapshot.sessions.filter { $0.phase == phase }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(phase == .needsYou ? "Needs you" : "Working")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(phase == .needsYou ? Color.accentColor : .secondary)
                            ForEach(rows) { row($0, in: snapshot) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "1 needs you · 3 working", the Mac's name trailing; "as of" replaces the name once stale.
    private func header(_ snapshot: WidgetSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if snapshot.waiting > 0 {
                Text("\(snapshot.waiting) needs you").foregroundStyle(Color.accentColor).widgetAccentable()
                    .contentTransition(.numericText(value: Double(snapshot.waiting)))
                Text(" · ").foregroundStyle(.secondary)
            }
            Text("\(snapshot.working) working")
                .contentTransition(.numericText(value: Double(snapshot.working)))
            Spacer(minLength: 6)
            Text(entry.asOf ?? snapshot.macName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
        .monospacedDigit()
    }

    private func row(_ session: WidgetSnapshot.Session, in snapshot: WidgetSnapshot) -> some View {
        Link(destination: snapshot.sessionURL(session.id) ?? URL(string: "sidea-remote://")!) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                glyph(session.phase)
                VStack(alignment: .leading, spacing: 1) {
                    // A Link tints its label; titles stay in the label colour.
                    Text(session.title).font(.subheadline.weight(.medium)).foregroundStyle(Color(.label)).lineLimit(1)
                    if let line = session.line {
                        Text(line)
                            .font(session.phase == .working ? .caption.monospaced() : .caption)
                            .foregroundStyle(session.phase == .needsYou ? Color("AmberText") : Color(.secondaryLabel))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The app's glyphs, still: an amber ring for needs you, the progress mark for working.
    private func glyph(_ phase: WidgetSnapshot.Session.Phase) -> some View {
        Group {
            if phase == .needsYou {
                Image(systemName: "circle.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.accentColor, Color.accentColor.opacity(0.3))
                    .widgetAccentable()
            } else {
                Image(systemName: "progress.indicator").foregroundStyle(Color(.secondaryLabel))
            }
        }
        .font(.subheadline)
        .frame(width: 18)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Nothing running").font(.subheadline.weight(.medium))
            Text("Start a session from the app or a terminal.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: Lock Screen

    @ViewBuilder private func rectangular(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: snapshot.waiting > 0 ? "circle.circle.fill" : "progress.indicator")
                Text(snapshot.waiting > 0 ? "\(snapshot.waiting) needs you" : "\(snapshot.working) working")
                    .contentTransition(.numericText(value: Double(snapshot.waiting > 0 ? snapshot.waiting : snapshot.working)))
            }
            .contentTransition(.symbolEffect(.replace))
            .font(.headline)
            .widgetAccentable()
            if let top = snapshot.top {
                Text("\(top.headline) · \(top.detail)").font(.caption).lineLimit(1)
                Text(top.sessionTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if snapshot.waiting > 0 || snapshot.working > 0 {
                Text("\(snapshot.working) working on \(snapshot.macName)").font(.caption).lineLimit(1)
            } else {
                Text("Nothing running").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(snapshot.sessions.first.flatMap { snapshot.sessionURL($0.id) })
    }
}

#Preview("Medium", as: .systemMedium) {
    SessionsWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .placeholder)
}

#Preview("Large", as: .systemLarge) {
    SessionsWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .placeholder)
}
