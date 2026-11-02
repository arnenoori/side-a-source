import Foundation

/// The app's own files. build-app.sh puts them at fixed paths in the app, the bridge's Python files in
/// Contents/Resources/bridge and the rest in Contents/Resources, so the shipping app never depends on
/// how a toolchain lays out SwiftPM's resource bundle. That bundle only serves `swift run` and tests.
enum AppResources {
    static func bridge(_ file: String) -> URL? { url("bridge/" + file) }
    static func resource(_ file: String) -> URL? { url(file) }

    private static func url(_ path: String) -> URL? {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            let name = (path as NSString).lastPathComponent as NSString
            return Bundle.module.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension)
        }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(path),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
