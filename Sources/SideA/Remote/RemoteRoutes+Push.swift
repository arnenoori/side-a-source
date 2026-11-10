import CryptoKit
import Foundation
import SideACore
import SideAProtocol

/// The phone's push tokens, its push-key rotation and Test Connection's notification.
extension RemoteRoutes {
    static let pushRoutes: [Route] = [
        Route("POST", "v1/devices/push", registerPush),
        Route("POST", "v1/devices/rekey", rekey),
        Route("POST", "v1/diagnostics/push", diagnosticPush),
        Route("POST", "v1/diagnostics/push/{id}/received", diagnosticReceived),
    ]

    static let noRelay = RemoteServer.error(503, "relay_unavailable", "This Mac has no notification relay set up.", retryAfter: 60)

    /// Stored at once; the relay registration follows, and its outcome shows in setup.
    @Sendable static func registerPush(_ context: Context) async -> HTTPResponse {
        guard let registration = context.body(PushRegistration.self),
              registration.apnsToken.count <= 200, registration.apnsToken.allSatisfy(\.isHexDigit) else { return badJSON }
        let device = context.device
        await MainActor.run {
            let push = context.controller.push
            Task { @MainActor in _ = await push.register(device, registration) }
        }
        return HTTPResponse(status: 204)
    }

    /// Relay-and-release, Key rotation: a fresh exchange, the new key replacing the old at once on the Mac.
    @Sendable static func rekey(_ context: Context) async -> HTTPResponse {
        guard let request = context.body(RekeyRequest.self), let raw = Data(base64URL: request.devicePublicKey),
              let phone = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else { return badJSON }
        if let refused = await refusal(context, .rekey, body: request) { return refused }
        let device = context.device
        return await MainActor.run {
            let controller = context.controller
            guard controller.relayURL != nil, let installID = controller.installID else { return noRelay }
            let mine = Curve25519.KeyAgreement.PrivateKey()
            guard let key = try? PushKey.derive(mine, peer: phone, macPublicKey: mine.publicKey.rawRepresentation, devicePublicKey: raw,
                                                installID: installID, deviceID: device),
                  (try? controller.devices.update(device, { $0.pushKey = key.data; $0.pushKeyID = key.keyID })) == true else {
                return RemoteServer.error(500, "internal", "Side A couldn't save the new notification key.")
            }
            return json(200, RekeyResponse(macPublicKey: mine.publicKey.rawRepresentation.base64URL, keyID: key.keyID.base64URL))
        }
    }

    @Sendable static func diagnosticPush(_ context: Context) async -> HTTPResponse {
        let device = context.device
        let push = await MainActor.run { context.controller.push }
        guard await MainActor.run(body: { context.controller.relayURL != nil && context.controller.installID != nil }) else { return noRelay }
        return json(200, await push.test(device))
    }

    @Sendable static func diagnosticReceived(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? "", device = context.device
        let known = await MainActor.run { context.controller.push.received(id, from: device) }
        return known ? HTTPResponse(status: 204) : RemoteServer.error(404, "not_found", "Side A didn't send that test.")
    }
}
