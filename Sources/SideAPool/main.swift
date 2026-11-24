import Foundation
import SideACore

let home = FileManager.default.homeDirectoryForCurrentUser
/// An update or a rebuild replaces this file; its modification time says when.
func installed() -> String? {
    guard let path = Bundle.main.executableURL?.path,
          let date = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date else { return nil }
    return String(date.timeIntervalSince1970)
}
/// The helper runs from inside the app's bundle, so that bundle is the Side A to open. In the background: nobody asked.
func reopen() {
    let bundle = Bundle.main.bundleURL
    guard bundle.pathExtension == "app" else { return }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", bundle.path]
    do { try open.run() } catch {
        FileHandle.standardError.write(Data("couldn't reopen Side A: \(error.localizedDescription)\n".utf8))
    }
}
let helper = PoolHelper(root: home.appendingPathComponent("Library/Application Support/SideA"), version: installed() ?? "unknown",
                        installed: installed, logs: home.appendingPathComponent("Library/Logs/SideA"),
                        bundle: Bundle.main.bundleURL.path, reopen: reopen)
exit(await helper.run())
