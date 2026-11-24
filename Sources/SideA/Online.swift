import Foundation
import Network

final class Online: @unchecked Sendable {
    static let shared = Online()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var satisfied = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.withLock { self.satisfied = path.status == .satisfied }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    var value: Bool { lock.withLock { satisfied } }
}
