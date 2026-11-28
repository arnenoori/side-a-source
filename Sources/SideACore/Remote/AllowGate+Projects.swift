import Foundation

extension AllowGate {
    /// The folders a request's session counts as its project: its own and the git root above it. `AllowGate.of` judges
    /// "inside the project" by these, on the Mac and on a headless host alike.
    public static func projectRoots(of cwd: String?) -> [String] {
        guard let cwd, !cwd.isEmpty else { return [] }
        var url = URL(fileURLWithPath: cwd).standardizedFileURL
        var roots = [url.path]
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                if url.path != cwd { roots.append(url.path) }
                break
            }
            url.deleteLastPathComponent()
        }
        return roots
    }
}
