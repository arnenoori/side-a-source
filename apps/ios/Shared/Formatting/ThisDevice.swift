import Foundation

/// What the app calls the device it runs on, in copy like "Tailscale is off on this iPad". Read from the hardware model
/// rather than `UIDevice`, so extensions and code off the main actor can say it too.
public enum ThisDevice {
    /// "iPhone" or "iPad", or "Mac" for the iPad app on an Apple silicon Mac, whose model names neither.
    public static let kind = ProcessInfo.processInfo.isiOSAppOnMac
        ? "Mac" : kind(model: ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine)

    public static var symbol: String {
        switch kind {
        case "iPad": "ipad"
        case "Mac": "laptopcomputer"
        default: "iphone"
        }
    }

    public static func kind(model: String) -> String { model.hasPrefix("iPad") ? "iPad" : "iPhone" }

    private static var machine: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
