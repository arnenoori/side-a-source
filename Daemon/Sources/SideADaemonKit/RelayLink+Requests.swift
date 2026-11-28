import Foundation
import SideACore
import SideAProtocol

/// What a waiting permission request has told the phones: which of them were sent its alert (so an answer takes it away from the
/// others), which are still open, and the follow-up that goes to a phone that was in front when the request came.
final class RequestPushes: @unchecked Sendable {
    private let lock = NSLock()
    private var shown = PushDismissals()
    private var open: Set<String> = []
    private var watchers: [String: Task<Void, Never>] = [:]

    func opened(_ id: String) { lock.withLock { _ = open.insert(id) } }
    func isOpen(_ id: String) -> Bool { lock.withLock { open.contains(id) } }
    func sent(_ collapse: String, to devices: [String]) { lock.withLock { shown.sent(collapse, to: devices) } }
    func showing(_ collapse: String) -> [String] { lock.withLock { shown.showing(collapse) } }

    /// The phones that still show the alert, once; the one that answered already took it away.
    func settled(_ id: String, collapse: String, answeredBy device: String?) -> [String] {
        lock.withLock {
            open.remove(id)
            watchers.removeValue(forKey: id)?.cancel()
            return shown.settled(collapse, answeredBy: device)
        }
    }

    func watch(_ id: String, _ task: Task<Void, Never>) {
        lock.withLock {
            watchers.removeValue(forKey: id)?.cancel()
            if open.contains(id) { watchers[id] = task } else { task.cancel() }
        }
    }

    func stop() { lock.withLock { watchers.values.forEach { $0.cancel() }; watchers = [:] } }
}

/// The push for a permission request, as the Mac sends it (`RemotePush.request`): sealed so the relay can't read it, time
/// sensitive, held back from a phone that is in front and sent to it when it stops being; and an "Answered" removal, or a plain
/// word on why nobody did, when the request ends.
extension RelayLink {
    static let watchEvery: Duration = .seconds(10)

    func request(_ request: RemoteRequest, daemon: SideADaemon) async {
        let collapse = RelayHTTP.collapse(request.id)
        requests.opened(request.id)
        let (category, payload) = RemotePushPayload.request(request, mac: daemon.config.hostID, now: Date().timeIntervalSince1970)
        let wanted: KeyPath<NotificationPrefs, Bool> = \.requests
        let delivery = await send(RemotePushPayload.encoded(payload), category: category, collapse: collapse, daemon: daemon, expiresIn: 3600, sound: true,
                                  wanted: wanted, timeSensitive: true)
        requests.sent(collapse, to: delivery.reached)
        guard !delivery.watching.isEmpty else { return }
        requests.watch(request.id, Task { [weak self, weak daemon] in
            var waiting = Set(delivery.watching)
            while !waiting.isEmpty, !Task.isCancelled {
                try? await Task.sleep(for: Self.watchEvery)
                guard let self, let daemon, !Task.isCancelled, self.requests.isOpen(request.id) else { return }
                let now = Date().timeIntervalSince1970
                let again = await self.send(RemotePushPayload.encoded(RemotePushPayload.request(request, mac: daemon.config.hostID, now: now).payload),
                                            category: category, collapse: collapse, daemon: daemon, expiresIn: 3600, sound: true, wanted: wanted,
                                            only: waiting, timeSensitive: true)
                self.requests.sent(collapse, to: again.reached)
                waiting = Set(again.watching)
            }
        })
    }

    /// Who ended a request that nobody answered, in words; nil when someone did (or the terminal did).
    static func unanswered(_ by: RequestResolution.By) -> String? {
        switch by {
        case .handedBack: "Handed back to the terminal"
        case .turnFinished: "The turn ended before it was answered"
        case .sessionEnded: "The session ended"
        default: nil
        }
    }

    func settled(_ request: RemoteRequest, _ resolution: RequestResolution, daemon: SideADaemon) async {
        let collapse = RelayHTTP.collapse(request.id)
        let why = Self.unanswered(resolution.by)
        let devices = requests.settled(request.id, collapse: collapse, answeredBy: why == nil ? resolution.deviceID : nil)
        guard !devices.isEmpty else { return }
        if let why {
            // The relay's own removal says "Answered", which would be untrue.
            let payload = RemotePushPayload.withdrawn(request, why: why, mac: daemon.config.hostID, now: Date().timeIntervalSince1970)
            await send(RemotePushPayload.encoded(payload), category: .health, collapse: collapse, daemon: daemon, expiresIn: 3600, sound: false,
                       wanted: \.requests, only: Set(devices), replaces: true)
            return
        }
        var at = 0
        while at < devices.count {
            let batch = Array(devices[at..<min(at + RelayHTTP.maxDevices, devices.count)])
            at += RelayHTTP.maxDevices
            _ = try? await http.send(RelayHTTP.Send(devices: batch, kind: "dismiss", collapseId: collapse, priority: 5))
        }
    }
}

extension SideADaemon {
    func requestOpened(_ request: RemoteRequest) async { await relay?.request(request, daemon: self) }
    func requestSettled(_ request: RemoteRequest, _ resolution: RequestResolution) async { await relay?.settled(request, resolution, daemon: self) }
}
