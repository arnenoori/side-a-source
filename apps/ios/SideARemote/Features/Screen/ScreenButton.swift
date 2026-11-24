import SideAProtocol
import SideARemoteKit
import SwiftUI

/// Shown whenever the Mac can serve it, switch on or off, so a person finds it and the view says where the switch is.
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
    /// Signs each screen open with the Face ID key, the mode bound in, so watching never signs for clicking.
    static func screen(macID: String, deviceID: String, kind: HostOS = .macos) -> @Sendable (ScreenMode) async -> String? {
        { mode in
            await header(.confirm, macID: macID, deviceID: deviceID, purpose: .screen, subject: ConfirmMessage.subject(screen: mode),
                         reason: mode == .control ? "Control \(kind.your())" : "See \(kind.your())'s screen")
        }
    }
}
