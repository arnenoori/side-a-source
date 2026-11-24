import SwiftUI

/// Light or dark for the app alone; `system` follows the phone.
enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance.theme"

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
