import AppKit

/// The app icon the user picked. A signed Mac app can't change its Finder icon, so this changes what the running
/// app shows: the Dock tile, the app switcher, About, alerts and the pairing card. The default is the bundle's icon.
struct AppIconChoice: Identifiable, Hashable {
    let id: String
    let name: String

    static let key = "appIcon"
    static let defaultChoice = AppIconChoice(id: "default", name: "Default")
    static let all: [AppIconChoice] = [defaultChoice] + [
        ("midnight", "Midnight"), ("cobalt", "Cobalt"), ("gold", "Gold"),
        ("glass", "Glass"), ("chrome", "Chrome"), ("crt-pixel", "CRT Pixel")
    ].map { AppIconChoice(id: $0.0, name: $0.1) }

    /// The icon the bundle shipped with, read before any choice replaces it.
    @MainActor private static let bundleIcon = NSApp?.applicationIconImage

    /// The saved choice; an id that isn't in the list (an older or newer build's) reads as the default.
    static func saved(in defaults: UserDefaults = .standard) -> AppIconChoice {
        let id = defaults.string(forKey: key)
        return all.first { $0.id == id } ?? defaultChoice
    }

    static func save(_ choice: AppIconChoice, in defaults: UserDefaults = .standard) {
        defaults.set(choice.id, forKey: key)
    }

    /// nil for the default: the Dock then goes back to the bundle's own icon.
    var image: NSImage? {
        guard self != Self.defaultChoice else { return nil }
        let url = AppResources.resource("AppIcons/\(id).png") ?? AppResources.resource("\(id).png")
            ?? Bundle.module.url(forResource: id, withExtension: "png", subdirectory: "AppIcons")
        return url.flatMap { NSImage(contentsOf: $0) }
    }

    @MainActor var preview: NSImage? { image ?? Self.bundleIcon }

    @MainActor static func apply(in defaults: UserDefaults = .standard) {
        _ = bundleIcon
        NSApp?.applicationIconImage = saved(in: defaults).image
    }
}
