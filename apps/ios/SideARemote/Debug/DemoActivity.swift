#if DEBUG
import ActivityKit
import Foundation
import SideAProtocol
import SideARemoteShared

/// `--demo-activity`: starts the Live Activity locally, as a push-to-start would, with one waiting
/// request whose words sit in the push cache like the Service Extension leaves them.
enum DemoActivity {
    static func start() {
        let payload = PushPayload(t: "request", mac: NotificationAnswer.demoMac, sent: Date.now.timeIntervalSince1970, rid: "demo-r1",
                                  sid: "s1", title: "Allow Bash", subtitle: "side-a · Work", body: "swift test --filter SyncEngineTests",
                                  gate: .unlock, agent: .claude)
        if let data = try? JSONEncoder().encode(payload) { PushCache.store(data, for: "demo-r1") }
        let state = MacActivityAttributes.ContentState(working: 3, waiting: 1, topRequest: "demo-r1",
                                                       soonestReset: .now.addingTimeInterval(2 * 3600 + 14 * 60), tightestPercent: 82)
        // ActivityKit only starts one for an app in the foreground, so after launch settles.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            do {
                _ = try Activity.request(attributes: MacActivityAttributes(macID: "demo"),
                                         content: ActivityContent(state: state, staleDate: .now.addingTimeInterval(30 * 60)))
            } catch {
                print("DemoActivity: \(error)")
            }
        }
    }
}
#endif
