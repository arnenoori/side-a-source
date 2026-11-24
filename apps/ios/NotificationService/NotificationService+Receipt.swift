import Foundation
import SideAProtocol
import SideARemoteKit
import SideARemoteShared

extension NotificationService {
    /// A test push's id is its collapse id. Telling the Mac it arrived is what turns "the relay accepted it" into "it
    /// got here"; it is the one request this extension makes, and it gives up early so the notification still shows.
    static let receiptTimeout = Duration.seconds(5)

    static func acknowledge(_ id: String, mac macID: String) async {
        guard let mac = PairedMac.load(macID) else { return }
        let client = RemoteClient(endpoint: mac.endpoint, credentials: KeychainCredentials())
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do { try await client.pushReceived(id) } catch {
                    RemoteLog.error(.push, "couldn't tell \(mac.endpoint.name) a test notification arrived: \(KitLog.describe(error))")
                }
            }
            group.addTask { try? await Task.sleep(for: receiptTimeout) }
            await group.next()
            group.cancelAll()
        }
    }
}
