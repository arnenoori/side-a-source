import Foundation
import SideACore
import SideAProtocol

/// Linking two computers, and the list of them for the phone (docs/remote/protocol.md, "Linking two computers").
extension RemoteRoutes {
    static let computerRoutes: [Route] = [
        Route("POST", "v1/computers", linkComputer),
        Route("DELETE", "v1/computers/{id}", unlinkComputer),
        Route("GET", "v1/computers", listComputers),
    ]

    static let notComputer = RemoteServer.error(403, .notComputer, "Only a linked computer can do that.")

    /// Whether the caller paired as another computer running Side A, not as a phone.
    @MainActor static func isComputer(_ context: Context) -> Bool {
        context.controller.devices.devices.first { $0.id == context.device }?.computer != nil
    }

    @Sendable static func linkComputer(_ context: Context) async -> HTTPResponse {
        guard let link = context.body(ComputerLink.self) else { return badJSON }
        return await onMainAsync(context) { _ in
            // A device speaks for one computer: the one it first named, and never this one.
            let named = context.controller.devices.devices.first { $0.id == context.device }?.computer
            guard let named, named.isEmpty || named == link.mac.id, link.mac.id != context.controller.mac.id else { return notComputer }
            do {
                return json(200, try context.controller.computers.accept(link, device: context.device, controller: context.controller))
            } catch {
                return RemoteServer.error(409, .moveRefused, "The link couldn't be saved: \(error.localizedDescription)")
            }
        }
    }

    @Sendable static func unlinkComputer(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        return await onMainAsync(context) { _ in
            guard isComputer(context) else { return notComputer }
            let controller = context.controller, device = context.device
            // Only its own link: the caller must be the device that computer comes in as, or one that names it.
            let named = controller.devices.devices.first { $0.id == device }?.computer == id
            guard controller.computers.dropped(id, by: device) || named else { return HTTPResponse(status: 204) }
            // After the answer has gone: revoking closes the connection it travels on.
            Task { @MainActor in controller.revoke(device) }
            return HTTPResponse(status: 204)
        }
    }

    @Sendable static func listComputers(_ context: Context) async -> HTTPResponse {
        await onMainAsync(context) { _ in
            json(200, ComputerList(computers: context.controller.computers.all.map { RemoteComputer(id: $0.id, name: $0.name, os: $0.endpoint.os) }))
        }
    }
}
