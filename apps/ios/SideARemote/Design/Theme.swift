import SideARemoteShared
import SwiftUI

/// Light or dark for the app alone; `system` follows the phone.
enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance.theme"

    /// For a window SwiftUI's scene doesn't own, such as the lock cover.
    static var current: Theme { SharedStorage.defaults.string(forKey: key).flatMap(Theme.init(rawValue:)) ?? .system }

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
