import SideARemoteShared
import SwiftUI
import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// Nil: no paired Mac, so the widget asks to pair.
    let snapshot: WidgetSnapshot?

    /// "as of 1:02" once the data is 15 minutes old (section 5.5).
    var asOf: String? {
        guard let snapshot, date.timeIntervalSince(snapshot.updatedAt) >= 15 * 60 else { return nil }
        return "as of \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))"
    }
}

/// The app reloads the widgets when the snapshot changes; the timeline only adds the moments the
/// view changes by itself: going stale, and the limit resetting.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: .now, snapshot: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview ? .placeholder : WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load()
        let now = Date.now
        let later = [snapshot.map { $0.updatedAt.addingTimeInterval(15 * 60) }, snapshot?.tightest?.resetsAt]
            .compactMap { $0 }.filter { $0 > now }.sorted()
        let entries = ([now] + later).map { SnapshotEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .never))
    }
}

/// Every widget's empty state before pairing.
struct PairFirst: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "laptopcomputer.and.iphone").font(.title3).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("Pair with your Mac").font(.subheadline.weight(.semibold))
            Text("Open Side A Remote to start.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Ring colour by how close a window is to its limit, as in the app: label colour, amber from 75%,
/// red from 97%.
func limitColor(_ percent: Double) -> Color {
    switch percent {
    case 97...: .red
    case 75...: .accentColor
    default: .primary
    }
}
