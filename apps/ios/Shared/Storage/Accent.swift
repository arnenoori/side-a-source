import SwiftUI

/// The app's tint, picked once after pairing and in Settings › Appearance. Brand only: "needs you" stays amber
/// whatever is picked. System colors, so each keeps its own dark and Increase Contrast variants.
public enum Accent: String, CaseIterable, Identifiable, Sendable {
    case blue, indigo, purple, pink, red, green, graphite

    public static let key = "appearance.accent"
    /// The App Group's defaults, so the notification card and widgets tint the same.
    nonisolated(unsafe) public static let store = UserDefaults(suiteName: SharedStorage.appGroup) ?? .standard

    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }

    public var color: Color { Color(uiColor) }

    public var uiColor: UIColor {
        switch self {
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .pink: .systemPink
        case .red: .systemRed
        case .green: .systemGreen
        case .graphite: .systemGray
        }
    }

    public static var current: Accent { store.string(forKey: key).flatMap(Accent.init(rawValue:)) ?? .blue }
    /// False until the user has picked one, so pairing again doesn't ask twice.
    public static var chosen: Bool { store.string(forKey: key) != nil }
}
