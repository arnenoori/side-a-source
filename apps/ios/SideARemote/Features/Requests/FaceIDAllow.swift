import LocalAuthentication
import SideAProtocol
import SideARemoteShared
import SwiftUI

/// Allow for a request the Mac gates with Face ID. The prompt names the command, so it is the confirmation: the card and
/// the sheet both go straight to it.
enum FaceIDAllow {
    enum Outcome: Equatable {
        /// Answer allow, with this signature when the Mac checks one.
        case granted(confirm: String?)
        /// The user backed out.
        case cancelled
        /// Face ID or the key failed.
        case failed
    }

    /// Face ID signs the answer with the confirm key, which the Mac checks. A Face ID from the last few minutes in the app,
    /// its unlock included, signs it (`DeviceKeys.adopt`). A pairing from before the keys falls back to asking here.
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
