import SideARemoteShared
import SwiftUI
import UIKit

/// The icon the app wears, held where every screen that draws the logo can watch it.
@Observable
final class AppIconChoice {
    nonisolated deinit {}

    static let shared = AppIconChoice()

    private(set) var option: AppIconOption

    private init() {
        option = AppIconOption(iconName: UIApplication.shared.alternateIconName)
        #if DEBUG
        // The Simulator can refuse the switch; a launch argument shows what each icon looks like in the app.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--app-icon"), index + 1 < arguments.count,
           let forced = AppIconOption(rawValue: arguments[index + 1]) { option = forced }
        #endif
    }

    /// False when iOS refused and the icon stayed as it was.
    func switchTo(_ new: AppIconOption) async -> Bool {
        do {
            try await UIApplication.shared.setAlternateIconName(new.iconName)
            option = new
            return true
        } catch {
            RemoteLog.error(.app, "app icon: could not switch to \(new.name): \(error.localizedDescription)")
            // The Simulator reports a failure after it has switched; what iOS now says is the truth.
            let actual = AppIconOption(iconName: UIApplication.shared.alternateIconName)
            guard actual != option else { return false }
            option = actual
            return true
        }
    }
}

/// The chosen app icon drawn inside the app.
struct AppIconArt: View {
    let side: CGFloat

    var body: some View {
        Image(AppIconOption.current.art)
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: side * 0.2237, style: .continuous))
            .accessibilityHidden(true)
    }
}
