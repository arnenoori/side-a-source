import Foundation

/// Which of a folder's files an `@` mention means, best first. A match in the file's name beats one in its folders, a
/// name that starts with the query beats one that holds it, and letters in order (`sv` for `SettingsView`) come last.
public enum FileRank {
    public static func matches(_ query: String, in paths: [String], limit: Int = 40) -> [String] {
        let query = query.lowercased()
        guard !query.isEmpty else { return Array(paths.sorted { depth($0) == depth($1) ? $0 < $1 : depth($0) < depth($1) }.prefix(limit)) }
        var scored: [(score: Int, path: String)] = []
        for path in paths {
            guard let score = score(query, path) else { continue }
            scored.append((score, path))
        }
        return scored.sorted { $0.score == $1.score ? ($0.path.count, $0.path) < ($1.path.count, $1.path) : $0.score < $1.score }
            .prefix(limit).map(\.path)
    }

    private static func depth(_ path: String) -> Int { path.utf8.reduce(0) { $1 == UInt8(ascii: "/") ? $0 + 1 : $0 } }

    /// Lower is better; nil when the path doesn't match at all.
    static func score(_ query: String, _ path: String) -> Int? {
        let lowered = path.lowercased()
        let name = lowered.split(separator: "/").last.map(String.init) ?? lowered
        if query.contains("/") {
            if lowered.hasPrefix(query) { return 0 }
            if lowered.contains(query) { return 1 }
            return inOrder(query, lowered) ? 6 : nil
        }
        if name == query { return 0 }
        if name.hasPrefix(query) { return 1 }
        if name.contains(query) { return 2 }
        if lowered.contains(query) { return 3 }
        if inOrder(query, name) { return 4 }
        return inOrder(query, lowered) ? 5 : nil
    }

    private static func inOrder(_ query: String, _ text: String) -> Bool {
        var rest = Substring(text)
        for character in query {
            guard let found = rest.firstIndex(of: character) else { return false }
            rest = rest[rest.index(after: found)...]
        }
        return true
    }
}
