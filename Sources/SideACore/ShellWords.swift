import Foundation

/// What a shell would make of a command, closely enough for the destructive rules: words with their quotes gone, split
/// at the shell's own metacharacters, with redirection targets and substitutions pulled out. It runs nothing and
/// expands nothing. Anything it can't follow says so, and the caller holds that to more, not less.
enum ShellWords {
    struct Segment: Equatable {
        var words: [String] = []
        /// Which words hold a substitution or a variable.
        var dynamic: [Bool] = []
        /// Files `>` and `>>` write.
        var writes: [String] = []
        /// What it reads on stdin comes from the command before it.
        var piped = false
        /// A heredoc or here-string is its stdin.
        var hereInput = false
    }

    struct Parsed: Equatable {
        var segments: [Segment] = []
        var unreadable = false
    }

    static func parse(_ command: String) -> Parsed {
        var parsed = Parsed()
        let scalars = Array(command.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars)
        scan(scalars, into: &parsed, depth: 0)
        return parsed
    }

    private static func scan(_ text: [Unicode.Scalar], into parsed: inout Parsed, depth: Int) {
        guard depth < 8 else { parsed.unreadable = true; return }
        var segment = Segment()
        var word = String.UnicodeScalarView()
        var inWord = false, dynamic = false, redirect = false, hereDelimiter = false
        var heredocs: [String] = []
        var i = 0

        func inner(_ body: [Unicode.Scalar], _ parsed: inout Parsed) { scan(body, into: &parsed, depth: depth + 1) }

        func endWord() {
            guard inWord else { return }
            let text = String(word)
            if hereDelimiter { heredocs.append(text); hereDelimiter = false }
            else if redirect { segment.writes.append(text); redirect = false }
            else { segment.words.append(text); segment.dynamic.append(dynamic) }
            word = String.UnicodeScalarView(); inWord = false; dynamic = false
        }
        func endSegment(_ parsed: inout Parsed) {
            endWord()
            redirect = false
            let empty = segment.words.isEmpty && segment.writes.isEmpty
            if !empty { parsed.segments.append(segment) }
            // `a | (sh)`: the pipe still feeds what comes next.
            segment = Segment(piped: empty && segment.piped)
        }
        /// `$(…)`'s end, quotes respected. Nil when it never closes.
        func closing(from start: Int) -> Int? {
            var depthHere = 1, j = start, quote: Unicode.Scalar?
            while j < text.count {
                let c = text[j]
                if let open = quote {
                    if c == "\\", open == "\"" { j += 1 } else if c == open { quote = nil }
                } else if c == "'" || c == "\"" { quote = c }
                else if c == "\\" { j += 1 }
                else if c == "(" { depthHere += 1 }
                else if c == ")" { depthHere -= 1; if depthHere == 0 { return j } }
                j += 1
            }
            return nil
        }
        /// At `$(` or a backtick: parses what's inside as commands of their own; true when it could.
        func substitution(_ parsed: inout Parsed) -> Bool {
            if text[i] == "`" {
                var j = i + 1
                while j < text.count, text[j] != "`" { j += text[j] == "\\" ? 2 : 1 }
                guard j < text.count else { return false }
                inner(Array(text[(i + 1)..<j]), &parsed)
                word.append("`"); inWord = true; dynamic = true
                i = j + 1
                return true
            }
            guard let end = closing(from: i + 2) else { return false }
            inner(Array(text[(i + 2)..<end]), &parsed)
            word.append("$"); inWord = true; dynamic = true
            i = end + 1
            return true
        }

        while i < text.count {
            let c = text[i]
            switch c {
            case "\\":
                if i + 1 < text.count {
                    if text[i + 1] != "\n" { word.append(text[i + 1]); inWord = true }
                    i += 2
                } else { parsed.unreadable = true; i += 1 }
            case "'":
                guard let end = text[(i + 1)...].firstIndex(of: "'") else { parsed.unreadable = true; endSegment(&parsed); return }
                word.append(contentsOf: text[(i + 1)..<end]); inWord = true
                i = end + 1
            case "\"":
                inWord = true
                i += 1
                var closed = false
                while i < text.count {
                    let d = text[i]
                    if d == "\"" { closed = true; i += 1; break }
                    if d == "\\", i + 1 < text.count { word.append(text[i + 1]); i += 2; continue }
                    if d == "`" || (d == "$" && i + 1 < text.count && text[i + 1] == "(") {
                        guard substitution(&parsed) else { parsed.unreadable = true; endSegment(&parsed); return }
                        continue
                    }
                    if d == "$" { dynamic = true }
                    word.append(d); i += 1
                }
                guard closed else { parsed.unreadable = true; endSegment(&parsed); return }
            case "`":
                guard substitution(&parsed) else { parsed.unreadable = true; endSegment(&parsed); return }
            case "$":
                if i + 1 < text.count, text[i + 1] == "(" {
                    guard substitution(&parsed) else { parsed.unreadable = true; endSegment(&parsed); return }
                } else {
                    word.append(c); inWord = true; dynamic = true; i += 1
                }
            case " ", "\t":
                endWord(); i += 1
            case "\n":
                endSegment(&parsed); i += 1
                // A heredoc's body is data: it ends at a line holding only its delimiter.
                for delimiter in heredocs {
                    var line = String.UnicodeScalarView()
                    while i < text.count {
                        let d = text[i]; i += 1
                        if d != "\n" { line.append(d); continue }
                        if String(line).trimmingCharacters(in: CharacterSet(charactersIn: "\t")) == delimiter { break }
                        line = String.UnicodeScalarView()
                    }
                }
                heredocs = []
            case ";", "(", ")":
                endSegment(&parsed); i += 1
            case "|":
                endSegment(&parsed)
                let next = i + 1 < text.count ? text[i + 1] : nil
                segment.piped = next != "|"
                i += next == "|" || next == "&" ? 2 : 1
            case "&":
                // `2>&1` and `>&2` duplicate a descriptor; anything else ends the command.
                if i > 0, text[i - 1] == ">" || text[i - 1] == "<" { i += 1; while i < text.count, text[i].properties.numericType != nil || text[i] == "-" { i += 1 } }
                else { endSegment(&parsed); i += 1 }
            case ">":
                endWord(); redirect = true; i += 1
                if i < text.count, text[i] == ">" || text[i] == "|" { i += 1 }
            case "<":
                endWord(); i += 1
                if i < text.count, text[i] == "<" {
                    segment.hereInput = true
                    i += 1
                    if i < text.count, text[i] == "<" { i += 1 }
                    else {
                        if i < text.count, text[i] == "-" { i += 1 }
                        hereDelimiter = true
                    }
                }
            case "#" where !inWord:
                while i < text.count, text[i] != "\n" { i += 1 }
            default:
                word.append(c); inWord = true; i += 1
            }
        }
        endSegment(&parsed)
    }

    /// A command with the words in front of it gone (assignments, `then`, `command`, `env`, `nice` …) and its name without
    /// a folder. `dynamic` when what runs comes from a variable or a substitution.
    static func command(_ segment: Segment) -> (words: [String], dynamic: Bool) {
        var words = segment.words, flags = segment.dynamic
        func drop(_ count: Int) { words.removeFirst(min(count, words.count)); flags.removeFirst(min(count, flags.count)) }
        func dropOptions(_ taking: Set<String>) {
            while let first = words.first, first.hasPrefix("-"), first.count > 1 { drop(taking.contains(first) ? 2 : 1) }
        }
        while let first = words.first {
            if first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\+?="#, options: .regularExpression) != nil { drop(1); continue }
            switch first {
            case "if", "then", "elif", "else", "do", "while", "until", "!", "{", "}", "time", "builtin", "nohup", "busybox", "caffeinate": drop(1)
            case "command":
                drop(1)
                if let flag = words.first, flag == "-v" || flag == "-V" { return ([], false) }
                dropOptions([])
            case "exec": drop(1); dropOptions(["-a"])
            case "nice": drop(1); dropOptions(["-n"])
            case "env": drop(1); dropOptions(["-u", "-C", "-S"])
            case "timeout", "gtimeout": drop(1); dropOptions(["-k", "-s"]); drop(1)
            case "stdbuf": drop(1); dropOptions(["-i", "-o", "-e"])
            case "arch": drop(1); dropOptions(["-arch", "-e", "-d"])
            case "xargs": drop(1); dropOptions(["-I", "-J", "-L", "-n", "-P", "-R", "-S", "-s", "-E", "-d"])
            case "setsid", "unbuffer", "chronic": drop(1); dropOptions([])
            default:
                if flags.first == true, !plainBase(first) { return (words, true) }
                if first.contains("/") { words[0] = URL(fileURLWithPath: first).lastPathComponent }
                return (words, false)
            }
        }
        return ([], false)
    }

    /// `$HOME/bin/x` names a fixed place; `$RUNNER` doesn't.
    private static func plainBase(_ word: String) -> Bool {
        word.range(of: #"^(\$HOME|\$\{HOME\}|\$PWD|\$\{PWD\})/[^$`]+$"#, options: .regularExpression) != nil
    }

    /// The words that may name a file: not the command, flags alone, what `echo` prints, or the pattern `grep` looks for.
    static func pathWords(_ words: [String]) -> [String] {
        let args = Array(words.dropFirst())
        switch words.first {
        case "echo", "printf": return []
        case "grep", "egrep", "fgrep", "rg", "ag", "ack":
            var seen = false
            return args.filter { word in
                if word.hasPrefix("-") { return false }
                defer { seen = true }
                return seen
            }
        default: return args
        }
    }

    /// A word as paths: itself, after `name=`, after a short option (`-oFILE`), after `@` (curl's `-d @file`), and after a URL scheme for files.
    static func pathForms(_ word: String) -> [String] {
        var forms = [word]
        if word.hasPrefix("-"), !word.hasPrefix("--"), word.count > 2 { forms.append(String(word.dropFirst(2))) }
        if let equals = word.firstIndex(of: "=") { forms.append(String(word[word.index(after: equals)...])) }
        for form in forms where form.hasPrefix("@") { forms.append(String(form.dropFirst())) }
        for form in forms where form.hasPrefix("file://") { forms.append(String(form.dropFirst(7))) }
        return forms
    }

    /// Commands that only look at what they name. Anything else may write to any path it is given: `cp -t`, `curl -o`, `patch`.
    static func onlyReads(_ words: [String]) -> Bool {
        guard let name = words.first else { return true }
        if name == "find" { return !words.contains { findWrites.contains($0) || findRuns.contains($0) } }
        return ["ls", "cat", "head", "tail", "less", "more", "stat", "file", "wc", "diff", "cmp", "bat", "grep", "egrep", "fgrep", "rg", "ag", "ack", "echo", "printf",
                "test", "[", "[[", "du", "readlink", "realpath", "basename", "dirname", "md5", "shasum", "sha256sum", "xxd", "hexdump", "strings", "tree", "cd", "pushd",
                "source", ".", "which", "type"].contains(name)
    }

    private static let findRuns: Set<String> = ["-exec", "-execdir", "-ok", "-okdir"]
    private static let findWrites: Set<String> = ["-delete", "-fprint", "-fprint0", "-fprintf", "-fls"]

    /// What `find -exec` runs, as words of its own.
    static func findCommand(_ words: [String]) -> [String]? {
        guard words.first == "find", let flag = words.firstIndex(where: findRuns.contains) else { return nil }
        return Array(words[(flag + 1)...].prefix { $0 != ";" && $0 != "+" })
    }

    /// `{rm,-rf,x}` or `r[m]`: the shell makes the command's name up as it runs. `[` and `[[` are commands themselves.
    static func expands(_ name: String) -> Bool {
        !["[", "[["].contains(name) && name.contains { "*?[{".contains($0) }
    }

    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "ash", "csh", "tcsh"]

    /// A language runtime that takes a script as text.
    static func interpreter(_ name: String) -> Bool {
        name.range(of: #"^(python[0-9.]*|perl|ruby|node|deno|bun|php|lua)$"#, options: .regularExpression) != nil
    }

    /// The text of the code given on the command line: awk's program, or what `python3 -c` and the like take.
    static func inlineCode(_ words: [String]) -> String? {
        guard let name = words.first else { return nil }
        let args = words.dropFirst()
        if ["awk", "gawk", "mawk", "nawk"].contains(name) { return args.joined(separator: " ") }
        guard interpreter(name), args.contains(where: { $0 == "--eval" || $0 == "--print" || $0 == "eval" || $0.range(of: #"^-[a-zA-Z]*[cepr]$"#, options: .regularExpression) != nil }) else { return nil }
        return args.joined(separator: " ")
    }

    /// Where `cd` leaves things, nil once it can't be told.
    static func entered(_ words: [String], from cwd: String?) -> String? {
        guard let target = words.dropFirst().first(where: { !$0.hasPrefix("-") }), !target.contains("$"), !target.contains("`") else { return nil }
        return normalized(target.hasPrefix("/") || target.hasPrefix("~") ? target : (cwd.map { $0 + "/" } ?? "") + target)
    }

    /// A word as written, with its `..` gone, and as it reads from where `cd` left things.
    static func placed(_ word: String, in cwd: String?) -> [String] {
        var places = [word, normalized(word)]
        if let cwd, !word.hasPrefix("/"), !word.hasPrefix("~") { places.append(normalized(cwd + "/" + word)) }
        return places
    }

    private static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == "..", let last = parts.last, last != "..", last != "~" { parts.removeLast() } else { parts.append(part) }
        }
        return (path.hasPrefix("/") ? "/" : "") + parts.joined(separator: "/")
    }

    /// The script in `bash -c '…'` or `eval …`, judged like any other command.
    static func inlineScript(_ words: [String]) -> String? {
        guard let name = words.first else { return nil }
        if name == "eval" { return words.dropFirst().joined(separator: " ") }
        guard shells.contains(name),
              let flag = words.dropFirst().firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.hasSuffix("c") }), flag + 1 < words.count else { return nil }
        return words[flag + 1]
    }

    private static let riskyGitKey = #"^(alias\.|core\.(sshcommand|hookspath|fsmonitor|pager|editor|gitproxy|askpass|attributesfile)|credential\.|diff\.(external|.*\.(textconv|command))|merge\..*\.driver|filter\.|protocol\.ext|include\.|includeif\.|gpg\.|pager\.|sequence\.editor|interactive\.difffilter|web\.browser|browser\.|man\.|remote\..*\.(uploadpack|receivepack|vcs|proxy)|uploadpack\.packobjectshook)"#
    private static let ranThroughGit = "Runs code through git's settings"

    private static func riskyKey(_ word: String) -> Bool { word.lowercased().range(of: riskyGitKey, options: .regularExpression) != nil }

    /// `GIT_SSH_COMMAND=x git fetch` runs x as surely as `core.sshCommand` does.
    static func riskyGitEnvironment(_ word: String) -> Bool {
        word.range(of: #"^GIT_(SSH|SSH_COMMAND|EXEC_PATH|CONFIG[A-Z_]*|ASKPASS|EDITOR|PAGER|SEQUENCE_EDITOR|EXTERNAL_DIFF|PROXY_COMMAND)="#, options: .regularExpression) != nil
    }

    /// Git's own options are in the way of a rule on its subcommand: `git -C . reset --hard`, `git -c a=b push --force`.
    static func gitRisk(_ words: [String]) -> String? {
        var i = 1
        var config: [String] = []
        while i < words.count, words[i].hasPrefix("-") {
            let option = words[i]
            if option.hasPrefix("--exec-path=") { return ranThroughGit }
            if option.hasPrefix("--config-env=") { config.append(String(option.dropFirst(13))); i += 1 }
            else if option.hasPrefix("-c"), !option.hasPrefix("--"), option.count > 2 { config.append(String(option.dropFirst(2))); i += 1 }
            else if ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix", "--config-env"].contains(option) {
                if option == "-c" || option == "--config-env", i + 1 < words.count { config.append(words[i + 1]) }
                i += 2
            } else { i += 1 }
        }
        if config.contains(where: riskyKey) { return ranThroughGit }
        guard i < words.count else { return nil }
        let args = Array(words[(i + 1)...])
        let shortFlag = { (letter: Character) in args.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains(letter) } }
        let thrownAway = "Throws away uncommitted work"
        let runs = ["--upload-pack", "--receive-pack", "--exec", "--extcmd"]
        if args.contains(where: { arg in runs.contains { arg == $0 || arg.hasPrefix($0 + "=") } }) { return ranThroughGit }
        switch words[i] {
        case "push":
            let over = args.contains { $0 == "--force" || $0.hasPrefix("--force-") || $0 == "--mirror" || $0 == "--delete" || $0 == "--prune" || $0.hasPrefix("+") || $0.hasPrefix(":") }
            return over || shortFlag("f") || shortFlag("d") ? "Force-pushes over remote history" : nil
        case "reset": return args.contains("--hard") || args.contains("--merge") ? thrownAway : nil
        case "clean": return shortFlag("f") || args.contains("--force") ? thrownAway : nil
        case "checkout": return args.contains("--") || shortFlag("f") || args.contains("--force") ? thrownAway : nil
        case "switch": return shortFlag("f") || args.contains("--force") || args.contains("--discard-changes") ? thrownAway : nil
        case "restore": return args.contains(".") || args.contains("--") || args.contains(":/") ? thrownAway : nil
        case "branch": return args.contains("-D") || (args.contains("--delete") && args.contains("--force")) ? thrownAway : nil
        case "stash": return args.first == "drop" || args.first == "clear" ? thrownAway : nil
        case "update-ref": return shortFlag("d") ? thrownAway : nil
        case "filter-branch", "filter-repo": return "Force-pushes over remote history"
        case "rebase": return shortFlag("x") ? ranThroughGit : nil
        case "bisect": return args.first == "run" ? ranThroughGit : nil
        case "submodule": return args.contains("foreach") ? ranThroughGit : nil
        case "config": return args.contains(where: riskyKey) ? ranThroughGit : nil
        default: return nil
        }
    }
}

/// A Codex patch's headers as Codex reads them: it trims each line, so an indented header counts.
public enum Patch {
    static let headers = ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "]

    /// A move's destination is a file it writes, judged like any other: a rename into .git/hooks runs.
    public static func files(_ patch: String) -> [String] {
        patch.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let line = line.trimmingCharacters(in: .whitespaces)
            for prefix in headers where line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
            return nil
        }
    }
}
