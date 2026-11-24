import SwiftUI

public enum Accent: String, CaseIterable, Identifiable, Sendable {
    case blue, indigo, purple, pink, red, green, graphite

    public static let key = "appearance.accent"

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

    public static var current: Accent { SharedStorage.defaults.string(forKey: key).flatMap(Accent.init(rawValue:)) ?? .blue }
    public static var chosen: Bool { SharedStorage.defaults.string(forKey: key) != nil }
}
