import Foundation
import SideACore

actor FileMentions {
    static let shared = FileMentions()
    static let most = 50_000

    private var listings: [String: (paths: [String], at: Date)] = [:]

    func matches(_ query: String, in folder: String) async -> [String] {
        FileRank.matches(query, in: await paths(in: folder))
    }

    private func paths(in folder: String) async -> [String] {
        if let found = listings[folder], Date().timeIntervalSince(found.at) < 30 { return found.paths }
        let paths = await Self.list(folder)
        listings = listings.filter { Date().timeIntervalSince($0.value.at) < 300 }
        listings[folder] = (paths, Date())
        return paths
    }

    /// Names the file route would refuse are left out too, so the phone never sees what it couldn't open. A hard-linked
    /// file isn't: that takes a stat of every file, and the route still refuses it.
    static func list(_ folder: String) async -> [String] {
        guard let root = FileReads.real(folder) else { return [] }
        let home = FileReads.real(NSHomeDirectory())
        let found: [String]
        if let listed = await gitListed(folder, timeout: 10) {
            found = listed
        } else if FileReads.wide(root, home: home) {
            // Walking the home folder reads every personal file name, and trips macOS's privacy prompts on the way.
            return []
        } else {
            found = await Task.detached { walk(folder) }.value
        }
        return found.filter { FileReads.listable($0, root: root, home: home) }
    }

    static func gitListed(_ folder: String, timeout: TimeInterval) async -> [String]? {
        // -z: names as they are, NUL between them, so one with a newline or a quote is still one name.
        let git = await ProcessRunner.run("/usr/bin/git", ["-C", folder, "ls-files", "-z", "--cached", "--others", "--exclude-standard"], timeout: timeout)
        guard git.launchError == nil, git.status == 0 else { return nil }
        return Array(String(decoding: git.output, as: UTF8.self).split(separator: "\0").prefix(most).map(String.init))
    }

    static let skipped: Set<String> = ["node_modules", "build", "dist", "DerivedData", "Pods", "target", "venv", "__pycache__"]

    static func walk(_ folder: String) -> [String] {
        let root = URL(fileURLWithPath: folder).standardizedFileURL
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var paths: [String] = []
        let home = FileReads.real(NSHomeDirectory())
        while let url = files.nextObject() as? URL, paths.count < most {
            if skipped.contains(url.lastPathComponent) || FileReads.personal(url.path + "/", home: home) { files.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            paths.append(String(url.standardizedFileURL.path.dropFirst(root.path.count + 1)))
        }
        return paths
    }
}

/// One file of a session's folder, for the phone's viewer. Symlinks are followed and the real file must still sit inside
/// the folder's real path. Only a regular file up to `most` with no other hard link goes, and never a key, a credential, anything under `.git`,
/// `~/Library` or a tool's sign-in folder (`personalFolders`), or anything hidden when the folder is the home folder or above it. A file git ignores does go: what an agent writes for reading is often in `out/` or `tmp/`.
enum FileReads {
    static let most = 20 << 20

    typealias Refusal = FileRefusal

    enum Failure: Error {
        case missing
        case folder
        case tooLarge
        case refused(Refusal)
    }

    static func read(_ path: String, in folder: String) async -> Result<Data, Failure> {
        let expanded = (path as NSString).expandingTildeInPath
        let asked = expanded.hasPrefix("/") ? expanded : (folder as NSString).appendingPathComponent(expanded)
        guard let root = real(folder), let file = real(asked) else { return .failure(.missing) }
        // By name first too, so nothing outside the folder, a device say, is ever opened.
        if let refused = refusal(file, asked: asked, root: root, home: real(NSHomeDirectory())) { return .failure(.refused(refused)) }
        return await Task.detached { opened(asked, root: root) }.value
    }

    /// A component can be swapped for a symlink after the name check, so the rules are asked again of the open file.
    /// Root and home go through F_GETPATH too: realpath may spell a folder's case differently.
    private static func opened(_ asked: String, root: String) -> Result<Data, Failure> {
        let fd = open(asked, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOCTTY)
        guard fd >= 0 else { return .failure(.missing) }
        defer { close(fd) }
        guard let file = path(of: fd), let root = held(root) else { return .failure(.missing) }
        if let refused = refusal(file, asked: asked, root: root, home: held(NSHomeDirectory())) { return .failure(.refused(refused)) }
        var status = stat()
        guard fstat(fd, &status) == 0 else { return .failure(.missing) }
        switch status.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFDIR: return .failure(.folder)
        default: return .failure(.missing)
        }
        // A hard link inside the folder has an inside path whatever file it is, an SSH key say, and no path says where
        // the others are. APFS package caches (pnpm, uv, bun) clone rather than link, so few project files have two.
        guard status.st_nlink <= 1 else { return .failure(.refused(.linked)) }
        guard status.st_size <= most else { return .failure(.tooLarge) }
        // To one byte past the limit: a file that grew after fstat is refused, not cut short.
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while data.count <= most {
            let wanted = min(chunk.count, most + 1 - data.count)
            let got = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, wanted) }
            if got < 0, errno == EINTR { continue }
            guard got >= 0 else { return .failure(.missing) }
            if got == 0 { break }
            data.append(contentsOf: chunk[..<got])
        }
        return data.count <= most ? .success(data) : .failure(.tooLarge)
    }

    private static func refusal(_ file: String, asked: String, root: String, home: String?) -> Refusal? {
        let base = root.hasSuffix("/") ? root : root + "/"
        guard file.hasPrefix(base) else { return .outside }
        let parts = String(file.dropFirst(base.count)).split(separator: "/").map(String.init)
        if secret(parts) || secret([(asked as NSString).lastPathComponent]) || personal(file, home: home) || (wide(root, home: home) && parts.contains { $0.hasPrefix(".") }) {
            return .secret
        }
        return nil
    }

    private static func path(of fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(cString: buffer)
    }

    private static func held(_ folder: String) -> String? {
        let fd = open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return path(of: fd)
    }

    static let signInFolders = [".ssh", ".aws", ".gnupg", ".docker", ".kube", ".codex"]
    static let secretFolders = Set(signInFolders + [".git", ".azure", ".gcloud", ".terraform"])
    static let secretNames: Set<String> = [
        ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".dev.vars", ".zsh_history", ".bash_history", "auth.json", "hosts.yml",
        "credentials", "pool-key", "pool-share-key",
    ]
    static let secretExtensions: Set<String> = [
        "pem", "p12", "pfx", "key", "p8", "jks", "keystore", "env", "tfstate", "tfvars", "kdbx", "keychain", "keychain-db",
        "mobileprovision",
    ]
    static let secretPrefixes = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".env", "credentials.", ".credentials", "service-account", "secrets."]

    static func listable(_ path: String, root: String, home: String?) -> Bool {
        !secret(path.split(separator: "/").map(String.init)) && !personal(root + "/" + path, home: home)
    }

    static func secret(_ components: [String]) -> Bool {
        components.contains { part in
            let name = part.lowercased()
            return secretFolders.contains(name) || secretNames.contains(name) || name.contains(".tfstate")
                || secretExtensions.contains((name as NSString).pathExtension) || secretPrefixes.contains { name.hasPrefix($0) }
        }
    }

    /// The home folder, or a folder that holds it: a session started there has the whole account "inside its folder", so
    /// nothing hidden is served from it. A folder inside a personal one is as wide: everything in it is someone's state.
    static func wide(_ root: String, home: String? = real(NSHomeDirectory())) -> Bool {
        guard let home else { return true }
        return root == "/" || home == root || home.hasPrefix(root.hasSuffix("/") ? root : root + "/") || personal(root + "/", home: home)
    }

    /// Refused whatever the session's folder: one started in `~/.claude` has its OAuth tokens "inside its folder".
    static let personalFolders = ["Library", ".claude", ".config"] + signInFolders

    static func personal(_ file: String, home: String? = real(NSHomeDirectory())) -> Bool {
        guard let home else { return true }
        return personalFolders.contains { file.hasPrefix(home + "/" + $0 + "/") }
    }

    static func real(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
