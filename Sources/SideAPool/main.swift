import Foundation
import SideACore

let home = FileManager.default.homeDirectoryForCurrentUser
/// An update or a rebuild replaces this file; its modification time says when.
func installed() -> String? {
    guard let path = Bundle.main.executableURL?.path,
          let date = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date else { return nil }
    return String(date.timeIntervalSince1970)
}
let helper = PoolHelper(root: home.appendingPathComponent("Library/Application Support/SideA"), version: installed() ?? "unknown",
                        installed: installed, logs: home.appendingPathComponent("Library/Logs/SideA"))
exit(await helper.run())
