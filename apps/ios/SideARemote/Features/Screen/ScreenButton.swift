import SideAProtocol
import SideARemoteKit
import SwiftUI

struct ScreenButton: View {
    var hosted: String?
    var title = "Screen"
    @Environment(AppModel.self) private var model
    @State private var open: ScreenModel?

    var body: some View {
        if model.tools.can(.screen) {
            Button(title, systemImage: "display") {
                Task { open = await model.tools.screen(hosted: hosted) }
            }
            .fullScreenCover(item: $open) { screen in
                ScreenScreen(screen: screen)
                    .environment(model)
            }
        }
    }
}

nonisolated extension DeviceKeys {
    static func screen(macID: String, deviceID: String, kind: HostOS = .macos) -> @Sendable (ScreenMode) async -> String? {
        { mode in
            await header(.confirm, macID: macID, deviceID: deviceID, purpose: .screen, subject: ConfirmMessage.subject(screen: mode),
                         reason: mode == .control ? "Control \(kind.your())" : "See \(kind.your())'s screen")
        }
    }
}
