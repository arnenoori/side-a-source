import Foundation
import SideAProtocol

/// What a project's Git says changed, for the Changes sheet: the working tree against the last commit, the branch
/// against where it left the main one, and each commit since.
enum GitChanges {
    struct Commit: Identifiable, Hashable {
        let id: String
        let subject: String
        let at: Double
    }

    struct Failure: Error, Equatable { let message: String }

    /// A file's lines past this are left out, as in a turn's own diff.
    static let lineCap = 2000
    static let untrackedShown = 30
    static let untrackedLargest = 200 * 1024

    // MARK: Reading a unified diff

    static func parse(_ text: String, cap: Int = lineCap) -> [FileDiff] {
        var files: [FileDiff] = []
        var file: Draft?
        func close() { if let done = file?.finished() { files.append(done) }; file = nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                close()
                file = Draft(header: String(line), cap: cap)
            } else if file != nil {
                file?.take(line)
            }
        }
        close()
        return files
    }

    private struct Draft {
        var path: String
        var oldPath: String?
        var change = FileDiff.Change.modified
        var hunks: [DiffHunk] = []
        var open: (old: (start: Int, count: Int), new: (start: Int, count: Int), lines: [String])?
        var additions = 0, deletions = 0, kept = 0
        var truncated = false
        let cap: Int

        init(header: String, cap: Int) {
            // "diff --git a/x b/x": the name after " b/" is right unless the path itself holds " b/", which the
            // ---/+++ and rename lines that follow put right.
            let names = header.dropFirst("diff --git ".count)
            path = names.range(of: " b/", options: .backwards).map { String(names[$0.upperBound...]) } ?? String(names)
            self.cap = cap
        }

        mutating func take(_ line: Substring) {
            if line.hasPrefix("@@ ") {
                shut()
                let numbers = line.split(separator: " ").prefix(3).dropFirst().map { part -> (Int, Int) in
                    let pair = part.dropFirst().split(separator: ",").compactMap { Int($0) }
                    return (pair.first ?? 0, pair.count > 1 ? pair[1] : 1)
                }
                guard numbers.count == 2 else { return }
                open = (numbers[0], numbers[1], [])
            } else if open != nil, let sign = line.first, " +-\\".contains(sign) {
                if sign == "+" { additions += 1 } else if sign == "-" { deletions += 1 }
                if kept < cap { open?.lines.append(String(line)); kept += 1 } else { truncated = true }
            } else if open == nil {
                if line.hasPrefix("new file mode") { change = .added }
                else if line.hasPrefix("deleted file mode") { change = .deleted }
                else if line.hasPrefix("rename from ") { change = .renamed; oldPath = GitChanges.name(line.dropFirst("rename from ".count), prefix: "") }
                else if line.hasPrefix("rename to ") { path = GitChanges.name(line.dropFirst("rename to ".count), prefix: "") ?? path }
                else if line.hasPrefix("+++ ") { path = GitChanges.name(line.dropFirst(4), prefix: "b/") ?? path }
                else if line.hasPrefix("--- "), change == .deleted { path = GitChanges.name(line.dropFirst(4), prefix: "a/") ?? path }
            }
        }

        private mutating func shut() {
            if let open { hunks.append(DiffHunk(oldStart: open.old.start, oldCount: open.old.count, newStart: open.new.start, newCount: open.new.count, lines: open.lines)) }
            open = nil
        }

        mutating func finished() -> FileDiff {
            shut()
            return FileDiff(path: path, oldPath: oldPath, change: change, additions: additions, deletions: deletions, hunks: hunks, truncated: truncated)
        }
    }

    /// A file's name as a header line gives it. Git ends a name that has a space with a tab, and quotes one with a
    /// quote, a backslash or a control character, C style. Nil for `/dev/null` or a name without the prefix.
    static func name(_ written: Substring, prefix: String) -> String? {
        var text = written.last == "\t" ? String(written.dropLast()) : String(written)
        if text.count >= 2, text.first == "\"", text.last == "\"" {
            var bytes: [UInt8] = []
            var rest = Array(text.dropFirst().dropLast().utf8)[...]
            while let byte = rest.popFirst() {
                guard byte == UInt8(ascii: "\\"), let next = rest.popFirst() else { bytes.append(byte); continue }
                switch next {
                case UInt8(ascii: "t"): bytes.append(9)
                case UInt8(ascii: "n"): bytes.append(10)
                case UInt8(ascii: "r"): bytes.append(13)
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var value = Int(next - 48)
                    for _ in 0..<2 { if let digit = rest.first, (48...55).contains(digit) { value = value * 8 + Int(digit - 48); rest.removeFirst() } }
                    bytes.append(UInt8(truncatingIfNeeded: value))
                default: bytes.append(next)
                }
            }
            text = String(decoding: bytes, as: UTF8.self)
        }
        guard text.hasPrefix(prefix), text != "/dev/null" else { return nil }
        return String(text.dropFirst(prefix.count))
    }

    /// A file Git doesn't track yet, whole, as an added one. Nil for one that isn't text.
    static func added(_ path: String, contents: Data, cap: Int = lineCap) -> FileDiff? {
        guard !contents.contains(0), let text = String(data: contents, encoding: .utf8) else { return nil }
        var lines = text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }
        if text.hasSuffix("\n") { lines.removeLast() }
        let shown = Array(lines.prefix(cap))
        return FileDiff(path: path, change: .added, additions: lines.count, deletions: 0,
                        hunks: lines.isEmpty ? [] : [DiffHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: lines.count, lines: shown)],
                        truncated: lines.count > cap)
    }

    static func commits(_ log: String) -> [Commit] {
        log.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard parts.count == 3, let at = Double(parts[2]) else { return nil }
            return Commit(id: String(parts[0]), subject: String(parts[1]), at: at)
        }
    }

    // MARK: Asking Git

    static let git = "/usr/bin/git"

    /// Never waits on another Git's lock, never pages, and never runs a diff tool, text converter or file-system
    /// monitor the repository configured: an agent can write that configuration.
    private static func run(_ arguments: [String], in folder: String) async throws(Failure) -> String {
        let result = await ProcessRunner.run(git, ["-C", folder, "-c", "core.quotepath=false", "-c", "core.fsmonitor=false", "-c", "diff.noprefix=false", "-c", "diff.mnemonicPrefix=false", "--no-pager"] + arguments,
                                             environment: ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"], timeout: 30)
        if result.timedOut { throw Failure(message: "Git took too long to answer.") }
        guard result.launchError == nil, result.status == 0 else {
            let said = String(data: result.errors, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Git can answer with its whole usage text; the first line is the reason.
            let first = said.split(separator: "\n").first.map { String($0.prefix(200)) } ?? ""
            throw Failure(message: said.lowercased().contains("not a git repository") ? "This folder isn't a Git repository." : first.isEmpty ? "Git couldn't read the changes." : first)
        }
        return String(decoding: result.output, as: UTF8.self)
    }

    private static let plain = ["--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/", "-M"]
    private static let diff = ["diff"] + plain

    /// The working tree against the last commit, with the files Git doesn't track yet.
    static func uncommitted(in folder: String) async throws(Failure) -> [FileDiff] {
        let top = try await run(["rev-parse", "--show-toplevel"], in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
        // A repository with no commit yet has nothing to compare with: everything in it is untracked.
        let born = (try? await run(["rev-parse", "--verify", "--quiet", "HEAD"], in: folder)) != nil
        var files = born ? parse(try await run(diff + ["HEAD", "--"], in: folder)) : []
        // A folder Git tracks nothing in is one entry, so a new `node_modules` isn't listed file by file.
        let untracked = try await run(["ls-files", "--others", "--exclude-standard", "--directory", "--full-name", "-z", "--", ":/"], in: folder)
        let names = untracked.split(separator: "\0").map(String.init).prefix(untrackedShown)
        files += await Task.detached { () -> [FileDiff] in
            names.compactMap { name in
                if name.hasSuffix("/") { return FileDiff(path: name, change: .added, additions: 0, deletions: 0, hunks: []) }
                let url = URL(fileURLWithPath: top).appendingPathComponent(name)
                // Only a plain file is read: a pipe would never end, and a link could point anywhere.
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= untrackedLargest,
                      let data = try? Data(contentsOf: url) else { return nil }
                return added(name, contents: data)
            }
        }.value
        return files
    }

    /// Where the branch left the main one: the remote's default branch, else `main`, else `master`.
    static func base(in folder: String) async -> String? {
        var names: [String] = []
        if let head = try? await run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: folder) {
            names.append(head.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for name in names + ["origin/main", "main", "origin/master", "master"] where !name.isEmpty {
            if let found = try? await run(["merge-base", "HEAD", name], in: folder) {
                return found.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// Everything since the branch left the main one, committed or not.
    static func sinceBase(in folder: String) async throws(Failure) -> [FileDiff] {
        guard let base = await base(in: folder) else { throw Failure(message: "There is no main branch to compare with.") }
        return parse(try await run(diff + [base, "--"], in: folder))
    }

    static func commits(in folder: String) async throws(Failure) -> [Commit] {
        guard let base = await base(in: folder) else { throw Failure(message: "There is no main branch to compare with.") }
        return commits(try await run(["log", "--format=%H%x1f%s%x1f%ct", "-n", "50", "\(base)..HEAD"], in: folder))
    }

    static func commit(_ id: String, in folder: String) async throws(Failure) -> [FileDiff] {
        guard id.range(of: "^[0-9a-f]{7,64}$", options: .regularExpression) != nil else { throw Failure(message: "That isn't a commit.") }
        return parse(try await run(["show"] + plain + ["--diff-merges=first-parent", "--format=", id, "--"], in: folder))
    }
}

/// A remark on one line of a diff, gathered with others into one message to the agent.
struct DiffComment: Identifiable, Equatable {
    let id: UUID
    /// Which changes it was made on: the same file and line in another commit is another line.
    var scope = ""
    let path: String
    /// The line in the file as it is now; for a removed line, where it was.
    let line: Int
    let removed: Bool
    let quote: String
    var text: String
}

enum DiffReview {
    /// The line a hunk's `index`th row is, in the new file, or in the old one for a removed row. Nil for "\ No newline".
    static func line(of index: Int, in hunk: DiffHunk) -> (line: Int, removed: Bool)? {
        guard hunk.lines.indices.contains(index), let sign = hunk.lines[index].first, sign != "\\" else { return nil }
        var old = hunk.oldStart, new = hunk.newStart
        for earlier in hunk.lines[..<index] {
            switch earlier.first {
            case "+": new += 1
            case "-": old += 1
            case "\\": break
            default: old += 1; new += 1
            }
        }
        return sign == "-" ? (old, true) : (new, false)
    }

    /// One message: each remark under the file and line it is about, in the order of the files.
    static func message(_ comments: [DiffComment]) -> String {
        let kept = comments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !kept.isEmpty else { return "" }
        let body = kept.map { comment in
            let quote = comment.quote.trimmingCharacters(in: .whitespaces)
            let place = "\(comment.path):\(comment.line)" + (comment.removed ? " (removed line)" : "")
            return "\(place)\n" + (quote.isEmpty ? "" : "> \(quote.prefix(200))\n") + comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "Review comments on the changes:\n\n" + body.joined(separator: "\n\n")
    }
}
