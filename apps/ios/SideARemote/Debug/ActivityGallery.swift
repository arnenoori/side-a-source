#if DEBUG
import SideAProtocol
import SideARemoteShared
import SwiftUI

/// `--activity-gallery [first-last]`: the Live Activity's Lock Screen and Dynamic Island views in every state, drawn by
/// the widget's own views, because the Simulator's screenshots leave the island and Lock Screen out.
struct ActivityGallery: View {
    private typealias State = MacActivityAttributes.ContentState
    private let shown: ClosedRange<Int>

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--activity-gallery") else { return nil }
        let bounds = arguments.dropFirst(index + 1).first?.split(separator: "-").compactMap { Int($0) } ?? []
        shown = bounds.count == 2 ? bounds[0]...bounds[1] : 0...(Self.cases.count - 1)
        Self.seed()
    }

    private static let cases: [(String, State)] = [
        ("Waiting · unlock", State(working: 3, waiting: 1, topRequest: "g-unlock", tightestPercent: 82)),
        ("Waiting · Lock Screen", State(working: 2, waiting: 2, topRequest: "g-safe")),
        ("Waiting · Face ID", State(working: 1, waiting: 1, topRequest: "g-bio")),
        ("Long words", State(working: 12, waiting: 3, topRequest: "g-long")),
        ("Not cached", State(working: 2, waiting: 1, topRequest: "g-missing")),
        ("Working", State(working: 3, waiting: 0)),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(Self.cases[shown], id: \.0) { name, state in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(name).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                        LockScreenActivity(state: state, stale: false)
                            .frame(width: 364)
                            .background(.regularMaterial, in: .rect(cornerRadius: 24, style: .continuous))
                        HStack(spacing: 14) {
                            compact(state).dynamicTypeSize(...DynamicTypeSize.xxLarge)
                            MinimalActivity(state: state)
                                .frame(width: 37, height: 37)
                                .background(.black, in: .circle)
                                .environment(\.colorScheme, .dark)
                        }
                        expanded(state)
                    }
                }
            }
            .padding(.vertical, 60)
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity)
        }
        .background(LinearGradient(colors: [Color(red: 0.30, green: 0.36, blue: 0.48), Color(red: 0.12, green: 0.12, blue: 0.18)],
                                   startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    /// The pill around the camera: leading, the cutout, trailing.
    private func compact(_ state: State) -> some View {
        HStack(spacing: 0) {
            ActivityDisc(waiting: state.waiting > 0).padding(.leading, 10)
            Spacer(minLength: 126)
            CompactTrailing(state: state).padding(.trailing, 12)
        }
        .frame(height: 37)
        .frame(minWidth: 230)
        .background(.black, in: .capsule)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func expanded(_ state: State) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                IslandLeading(state: state)
                Spacer()
                IslandTrailing(state: state)
            }
            IslandCenter(state: state)
            IslandBottom(state: state)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 371)
        .background(.black, in: .rect(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    /// The Service Extension's decrypted payloads the cases point at.
    private static func seed() {
        let payloads = [
            PushPayload(t: "request", mac: "demo", sent: 0, rid: "g-unlock", title: "Allow Bash", subtitle: "side-a · Work",
                        body: "swift test --filter SyncEngineTests", gate: .unlock, agent: .claude),
            PushPayload(t: "request", mac: "demo", sent: 0, rid: "g-safe", title: "Allow Read", subtitle: "docs · Personal",
                        body: "docs/remote/ios-app.md", gate: .lockScreen, agent: .claude),
            PushPayload(t: "request", mac: "demo", sent: 0, rid: "g-bio", title: "Allow Bash", subtitle: "storefront · Team",
                        body: "rm -rf build/ && git clean -fdx", gate: .biometric, agent: .codex),
            PushPayload(t: "request", mac: "demo", sent: 0, rid: "g-long",
                        title: "Allow WebFetch on a very long hostname that keeps going",
                        subtitle: "an-unusually-long-project-name · Weekend side project",
                        body: "curl -sSL https://example.com/a/very/long/path/that/never/ends?with=query&and=more&params=true",
                        gate: .unlock, agent: .claude),
        ]
        for payload in payloads {
            if let rid = payload.rid, let data = try? JSONEncoder().encode(payload) { PushCache.store(data, for: rid) }
        }
    }
}
#endif
