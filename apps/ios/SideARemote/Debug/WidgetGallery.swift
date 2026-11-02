#if DEBUG
import SideARemoteShared
import SwiftUI
import WidgetKit

/// `--widget-gallery [dark]`: every widget at its iPhone size on the snapshot the app last wrote,
/// for screenshots where the Simulator's Home Screen can't be edited from a script.
struct WidgetGallery: View {
    private let entry: SnapshotEntry

    init?(arguments: [String]) {
        guard arguments.contains("--widget-gallery") else { return nil }
        let snapshot = WidgetSnapshot.load() ?? .placeholder
        entry = SnapshotEntry(date: .now, snapshot: arguments.contains("--stale") ? Self.stale(snapshot) : snapshot)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack(spacing: 20) {
                    tile(.systemSmall, width: 170, height: 170, lcd: true) { LimitWidgetView(entry: entry, familyOverride: $0) }
                    VStack(spacing: 14) {
                        lockScreen(.accessoryCircular, width: 72, height: 72) { LimitWidgetView(entry: entry, familyOverride: $0) }
                        lockScreen(.accessoryInline, width: 170, height: 24) { LimitWidgetView(entry: entry, familyOverride: $0) }
                    }
                }
                tile(.systemMedium, width: 364, height: 170) { SessionsWidgetView(entry: entry, familyOverride: $0) }
                tile(.systemMedium, width: 364, height: 170) { _ in AccountsWidgetView(entry: entry) }
                lockScreen(.accessoryRectangular, width: 172, height: 76) { SessionsWidgetView(entry: entry, familyOverride: $0) }
                tile(.systemLarge, width: 364, height: 382) { SessionsWidgetView(entry: entry, familyOverride: $0) }
            }
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity)
        }
        .background(LinearGradient(colors: [Color(red: 0.55, green: 0.47, blue: 0.40), Color(red: 0.25, green: 0.22, blue: 0.24)],
                                   startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private func tile(_ family: WidgetFamily, width: CGFloat, height: CGFloat, lcd: Bool = false,
                      @ViewBuilder content: (WidgetFamily) -> some View) -> some View {
        content(family)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .padding(16)
            .frame(width: width, height: height)
            .background(lcd ? AnyShapeStyle(Color.lcdPlate) : AnyShapeStyle(Color(.systemBackground)))
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
    }

    private func lockScreen(_ family: WidgetFamily, width: CGFloat, height: CGFloat, @ViewBuilder content: (WidgetFamily) -> some View) -> some View {
        content(family)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .foregroundStyle(.white)
            .frame(width: width, height: height)
            .background(.black.opacity(0.35), in: .rect(cornerRadius: 12))
            .environment(\.colorScheme, .dark)
    }

    private static func stale(_ snapshot: WidgetSnapshot) -> WidgetSnapshot {
        var snapshot = snapshot
        snapshot.updatedAt = .now.addingTimeInterval(-40 * 60)
        return snapshot
    }
}
#endif
