import LocalAuthentication
import SideAProtocol
import SideARemoteShared
import SwiftUI

enum FaceIDAllow {
    enum Outcome: Equatable {
        case granted(confirm: String?)
        case cancelled
        case failed
    }

    @MainActor
    static func ask(for request: RemoteRequest, on model: AppModel) async -> Outcome {
        let allow = RemoteAnswer.allow(confirmDestructive: true)
        // Face ID can't sign anything this Mac accepts; the answer's line says to pair again.
        if model.tools.needsKeys { return .granted(confirm: nil) }
        let reason = "Allow \(RequestText.visible(request.detail))"
        if let mac = model.link?.mac, DeviceKeys.has(.confirm, for: mac.endpoint.macID),
           let subject = try? ConfirmMessage.subject(requestID: request.id, answer: allow) {
            guard let confirm = await mac.sign(.confirm, purpose: .allow, subject: subject, reason: reason) else { return .failed }
            return .granted(confirm: confirm)
        }
        do {
            guard try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { return .cancelled }
            return .granted(confirm: nil)
        } catch let error as LAError where [.userCancel, .systemCancel, .appCancel].contains(error.code) {
            return .cancelled
        } catch {
            return .failed
        }
    }
}
