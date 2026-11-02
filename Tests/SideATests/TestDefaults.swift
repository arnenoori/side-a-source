import Foundation

/// Defaults in the temporary folder. A named suite leaves a plist in ~/Library/Preferences for good,
/// even after removePersistentDomain; a suite named by absolute path keeps it out of there.
func temporaryDefaults() -> UserDefaults {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("side-a-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return UserDefaults(suiteName: folder.appendingPathComponent("defaults.plist").path)!
}
