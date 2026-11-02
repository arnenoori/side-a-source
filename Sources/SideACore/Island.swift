import Foundation

public enum IslandAgent: String, Sendable, Codable {
    case claude, codex
    public var title: String { self == .claude ? "Claude Code" : "Codex" }
    public var provider: AgentProvider { self == .claude ? .claude : .codex }
}

/// One rule update Claude Code suggested, kept as it arrived so it can be sent back unchanged.
public struct IslandSuggestion: Sendable, Equatable {
    public let json: Data
    public let title: String
    public init(json: Data, title: String) { self.json = json; self.title = title }
}

public struct IslandRequest: Sendable, Equatable {
    public let agent: IslandAgent
    public let sessionID: String?
    public let cwd: String?
    public let tool: String
    public let action: IslandAction
    public let reason: String?
    public let suggestions: [IslandSuggestion]
    public let pid: Int?
    public let slot: String?
    public let headless: Bool
    /// From a Claude subagent (the hook's `agent_id`), which may run in the background with no prompt of its own.
    public let subagent: Bool
    /// The tmux session Side A hosts it in, from `SIDE_A_HOSTED`; nobody sits at that terminal.
    public let hosted: String?
    /// Codex's `CODEX_HOME`, which names the account it runs on.
    public let home: String?
    /// The tool's input as it arrived: questions and plans are answered by sending it back with the answer.
    public let input: Data
    public let risk: IslandRisk
    public let riskReason: String?

    public var project: String? { cwd.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } }

    public init?(message data: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let request = message["request"] as? [String: Any], let tool = request["tool_name"] as? String else { return nil }
        let input = request["tool_input"] as? [String: Any] ?? [:]
        agent = IslandAgent(rawValue: message["agent"] as? String ?? "") ?? .claude
        sessionID = request["session_id"] as? String
        cwd = request["cwd"] as? String
        self.tool = tool
        pid = message["pid"] as? Int
        slot = message["slot"] as? String
        headless = message["headless"] as? Bool ?? false
        subagent = agent == .claude && (request["agent_id"] as? String).map { !$0.isEmpty } == true
        hosted = (message["hosted"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        home = (message["home"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.input = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data("{}".utf8)
        action = Self.action(tool, input, mcp: request["mcp_server"] as? [String: Any])
        reason = (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        suggestions = agent == .claude ? (request["permission_suggestions"] as? [Any] ?? []).compactMap(Self.suggestion)
            : Self.codexSession(tool, action)
        (risk, riskReason) = Self.assess(tool, action, cwd: cwd)
    }

    /// The risk judged afresh, as it would be if the request arrived now: links in its paths may have changed since.
    public var currentRisk: IslandRisk { Self.assess(tool, action, cwd: cwd).0 }

    /// Always keeps a rule for next time, so it is never offered for a destructive request, nor for a command
    /// whose effect can't be read off it.
    public var offersAlways: Bool {
        guard !suggestions.isEmpty, risk != .destructive, !hidesText else { return false }
        if case .command(let command) = action { return !IslandRisk.opaque(command) }
        return true
    }

    /// A web search's query is words, not paths: ".env" in one is a question, not a read of a secret.
    static func assess(_ tool: String, _ action: IslandAction, cwd: String?) -> (IslandRisk, String?) {
        tool == "WebSearch" ? (.low, nil) : IslandRisk.assess(action, cwd: cwd)
    }

    public init(agent: IslandAgent, sessionID: String? = nil, cwd: String?, tool: String, action: IslandAction, reason: String? = nil,
                suggestions: [IslandSuggestion] = [], pid: Int? = nil, slot: String? = nil, headless: Bool = false,
                subagent: Bool = false, hosted: String? = nil, home: String? = nil) {
        self.agent = agent; self.sessionID = sessionID; self.cwd = cwd; self.tool = tool; self.action = action
        self.reason = reason; self.suggestions = suggestions; self.pid = pid; self.slot = slot; self.headless = headless
        self.subagent = subagent
        self.hosted = hosted; self.home = home
        input = Data("{}".utf8)
        (risk, riskReason) = Self.assess(tool, action, cwd: cwd)
    }

    static func action(_ tool: String, _ input: [String: Any], mcp: [String: Any]?) -> IslandAction {
        func text(_ key: String) -> String { input[key] as? String ?? "" }
        switch tool {
        case "Bash", "shell", "exec_command", "local_shell":
            let command = input["command"]
            if let parts = command as? [String] {
                // Codex hands over argv, usually ["bash", "-lc", "<script>"].
                return .command(parts.count == 3 && parts[1].hasPrefix("-") && parts[1].hasSuffix("c") ? parts[2] : parts.joined(separator: " "))
            }
            return .command(command as? String ?? "")
        case "Edit":
            return .edit(path: text("file_path"), removed: text("old_string"), added: text("new_string"))
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            return .edit(path: text("file_path"), removed: edits.compactMap { $0["old_string"] as? String }.joined(separator: "\n…\n"),
                         added: edits.compactMap { $0["new_string"] as? String }.joined(separator: "\n…\n"))
        case "Write":
            return .write(path: text("file_path"), content: text("content"))
        case "NotebookEdit":
            return .edit(path: text("notebook_path"), removed: "", added: text("new_source"))
        case "apply_patch":
            let patch = input["command"] as? String ?? input["patch"] as? String ?? input["input"] as? String ?? ""
            return .patch(files: Patch.files(patch), text: patch)
        case "Read":
            return .read(path: text("file_path"))
        case "AskUserQuestion":
            let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { entry -> IslandQuestion? in
                guard let question = entry["question"] as? String else { return nil }
                let options = (entry["options"] as? [[String: Any]] ?? []).compactMap { option in
                    (option["label"] as? String).map { IslandQuestion.Option(label: $0, description: option["description"] as? String) }
                }
                return IslandQuestion(question: question, header: entry["header"] as? String, options: options,
                                      multiSelect: entry["multiSelect"] as? Bool ?? false)
            }
            return .question(questions)
        case "ExitPlanMode":
            return .plan(text("plan"))
        case "WebFetch":
            return .fetch(text("url"))
        case "WebSearch":
            return .search(text("query"))
        case "Glob", "Grep":
            return .search([text("pattern"), text("path")].filter { !$0.isEmpty }.joined(separator: " in "))
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                let server = mcp?["name"] as? String ?? (parts.count > 1 ? String(parts[1]) : "MCP")
                let name = tool.components(separatedBy: "__").last ?? tool
                return .mcp(server: server, tool: name, arguments: compact(input))
            }
            return .other(tool: tool, arguments: compact(input))
        }
    }

    static func compact(_ input: [String: Any]) -> String {
        guard !input.isEmpty, let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func suggestion(_ value: Any) -> IslandSuggestion? {
        guard let entry = value as? [String: Any], let type = entry["type"] as? String,
              let json = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return nil }
        let place: String = switch entry["destination"] as? String {
        case "session": "for this session"
        case "localSettings": "in this project"
        case "projectSettings": "in this project, for everyone"
        case "userSettings": "everywhere"
        default: ""
        }
        let title: String
        switch type {
        case "addRules" where entry["behavior"] as? String == "allow":
            let rules = (entry["rules"] as? [[String: Any]] ?? []).compactMap { rule -> String? in
                guard let tool = rule["toolName"] as? String else { return nil }
                return (rule["ruleContent"] as? String).map { "\(tool)(\($0))" } ?? tool
            }
            guard !rules.isEmpty else { return nil }
            title = "Always allow \(rules.joined(separator: ", "))"
        case "setMode":
            guard let mode = entry["mode"] as? String, mode != "bypassPermissions" else { return nil }
            title = mode == "acceptEdits" ? "Accept all edits" : "Switch to \(mode) mode"
        case "addDirectories":
            let directories = (entry["directories"] as? [String] ?? []).map { URL(fileURLWithPath: $0).lastPathComponent }
            guard !directories.isEmpty else { return nil }
            title = "Always allow \(directories.joined(separator: ", "))"
        default:
            return nil
        }
        return IslandSuggestion(json: json, title: place.isEmpty ? title : "\(title) \(place)")
    }

    /// Codex's own "for this session" for edits, which a hook can't send back: the hook keeps it and allows later
    /// edits to the same files itself. Never for commands (the hook doesn't see a command's workdir or sandbox), nor
    /// for a patch that deletes a file.
    static func codexSession(_ tool: String, _ action: IslandAction) -> [IslandSuggestion] {
        guard tool == "apply_patch", case .patch(let files, let text) = action, !files.isEmpty, !text.contains("Delete File:") else { return [] }
        let title = files.count == 1 ? "Allow edits to \(file(files[0])) for the rest of the session"
            : "Allow edits to these \(files.count) files for the rest of the session"
        return [IslandSuggestion(json: Data(#"{"type":"codexSession"}"#.utf8), title: title)]
    }

    public var headline: String { DisplayText.escaped(action.headline) }
    public var detail: String { DisplayText.escaped(action.detail) }

    /// Hidden characters or padding somewhere in what the user is asked to judge.
    public var hidesText: Bool {
        action.shownText.contains { DisplayText.suspicious($0, longLines: action.isOneLiner) } || DisplayText.suspicious(reason ?? "", longLines: false)
    }

    public var announcement: String {
        let place = project.map { " in \($0)" } ?? ""
        switch action {
        case .question(let questions):
            let options = questions.first.map { $0.options.enumerated().map { "\($0.offset + 1), \($0.element.label)" }.joined(separator: "; ") } ?? ""
            return "\(agent.title) asks\(place): \(headline) Options: \(options). Control Option and a number picks one."
        case .plan(let plan):
            return "\(agent.title) wants approval for its plan\(place): \(IslandFinish.summary(plan))"
        default: break
        }
        let text = String(detail.prefix(140))
        let keys = risk == .destructive ? "This one needs a click." : "Control Option Y allows, Control Option N denies."
        return "\(agent.title) asks to \(headline.prefix(1).lowercased() + headline.dropFirst())\(place): \(text). \(keys)"
    }

    static func file(_ path: String) -> String { path.isEmpty ? "a file" : URL(fileURLWithPath: path).lastPathComponent }

    /// Whether `answer` may go back for this request, whoever sends it. A destructive request never takes an Always,
    /// and takes an Allow only when `confirmed`: a click on its own "Allow anyway", never a shortcut or a notification action.
    /// Every case is named, so a new kind of allow can't slip past the destructive guard.
    public func accepts(_ answer: IslandAnswer, confirmed: Bool) -> Bool {
        guard risk == .destructive else { return true }
        switch answer {
        case .always: return false
        case .allow, .allowMode: return confirmed
        case .deny, .terminal, .answers, .approvePlan: return true
        }
    }

    /// Told to the agent with every answer given by itself, since it wrote the options and the mark.
    public static let autoAnswerNote = " (Side A picked this after a minute; the user has not seen the question.)"

    /// What Side A sends by itself when this has waited a minute with answering with the recommended choice on: each
    /// question's options marked recommended, with `autoAnswerNote`. No form here or on the phone starts on the first
    /// option, so a question with none marked gets nil and waits. A plan is never approved this way, since the agent
    /// marks its own recommendation; so is no permission request.
    public var recommendedAnswer: IslandAnswer? {
        switch action {
        case .question(let questions) where !questions.isEmpty:
            var answers: [String: String] = [:]
            for question in questions {
                let marked = question.options.filter(\.recommended).map(\.label)
                guard let first = marked.first else { return nil }
                answers[question.question] = answers[question.question]
                    ?? question.answerText(picked: question.multiSelect ? marked : [first], other: nil) + Self.autoAnswerNote
            }
            return .answers(answers, input: input)
        default: return nil
        }
    }
}

extension IslandRisk {
    private static let commandRules: [(String, String)] = [
        (#"\brm\s+(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)\b"#, "Deletes files and folders"),
        (#"(^|[;&|(]\s*|\bxargs\s+|\bsudo\s+)rm\s"#, "Deletes files"),
        (#"\bsudo\b|\bdoas\b"#, "Runs as administrator"),
        (#"\bgit\s+push\b[^\n;&|]*(\s--force\b|\s-f\b|\s--force-with-lease\b|\s\+\S)"#, "Force-pushes over remote history"),
        (#"\bgit\s+(reset\s+--hard|clean\s+-[a-zA-Z]*f|checkout\s+--\s|restore\s+\.|branch\s+-D|stash\s+(drop|clear))"#, "Throws away uncommitted work"),
        (#"\b(curl|wget)\b[^\n|]*\|\s*(sudo\s+)?(ba|z|da)?sh\b"#, "Runs a script straight from the internet"),
        (#"\bdd\s+[^\n]*\bof=|\bmkfs\b|\bdiskutil\s+(erase|partition|zero)"#, "Writes to a disk"),
        (#"\bch(mod|own)\s+-[a-zA-Z]*R"#, "Changes permissions recursively"),
        (#"(?i)\b(drop\s+(table|database|schema)|truncate\s+table)\b|\bdelete\s+from\s+\w+\s*(;|$)"#, "Deletes database data"),
        (#"\bsecurity\s+(find-|delete-|dump-|export)|\bdefaults\s+delete\b"#, "Reads or removes system secrets"),
        (#"\b(npm|pnpm|yarn|cargo|gem|twine)\s+publish\b|\bgh\s+(release\s+create|pr\s+merge|repo\s+delete)\b|\bterraform\s+(apply|destroy)\b|\bkubectl\s+delete\b|\bvercel\b[^\n]*--prod"#,
         "Publishes, deploys or deletes remotely"),
        (#"\b(shutdown|reboot|halt)\b|\bkillall\b|\blaunchctl\s+(unload|bootout|remove)\b"#, "Stops the system or its services"),
        (#">\s*/dev/(disk|rdisk)|\bfind\b[^\n]*\s-delete\b|\bxargs\s+[^\n]*\brm\b"#, "Deletes many files at once"),
        (#"\bfind\b[^\n]*\s-exec(dir)?\s+(\S*/)?(rm|unlink|shred)\b"#, "Deletes many files at once"),
        (#"\brsync\b[^\n]*\s--(delete|remove-source-files)"#, "Deletes files as it copies"),
        (#"(^|[;&|(]\s*|\bsudo\s+)(truncate|shred|srm|unlink)\s"#, "Wipes files"),
        (#"\bshutil\.rmtree\b|\bos\.(remove|unlink|rmdir|removedirs)\s*\(|\.unlink\s*\(|\bfs\.(rm|rmdir|unlink)(Sync)?\s*\(|\brimraf\b|\bFileUtils\.rm|\bunlink\s*(\(|glob\b|["'$@])"#,
         "Deletes files from inline code"),
        (#"<\(\s*(curl|wget)\b|\$\(\s*(curl|wget)\b|`\s*(curl|wget)\b|\b(curl|wget)\b[^\n|]*\|\s*(sudo\s+)?(python3?|perl|ruby|node|osascript)\b"#,
         "Runs a script straight from the internet"),
        (#"\bosascript\b"#, "Scripts other apps"),
        (#"\bcrontab\s|\blaunchctl\s+(load|bootstrap|enable|submit)\b"#, "Schedules something to run later"),
    ]
    /// The agents' own settings and hooks: a bad write there changes what every session may do.
    private static let agentConfig = #"(^|/)\.claude/(settings(\.local)?\.json$|hooks/)|(^|/)\.codex/(hooks\.json|config\.toml)$|(^|/)\.claude\.json$"#
    private static let secretPaths = #"(^|/)(\.ssh/|\.aws/|\.gnupg/|\.netrc$|\.env(\.|$)|id_(rsa|ed25519|ecdsa)|\.npmrc$|\.pypirc$|Keychains/|credentials(\.json)?$)"#
    /// A template of an environment file holds no secrets.
    private static let secretTemplates = #"\.env\.(example|sample|template|dist)$"#
    /// What runs by itself later: a shell's startup files, launch agents, a repository's hooks and config.
    private static let runsLater = #"(^|/)\.(zshrc|zshenv|zprofile|zlogin|bashrc|bash_profile|profile)$|(^|/)Library/Launch(Agents|Daemons)(/|$)|(^|/)\.git/(hooks(/|$)|config$)"#

    /// A command whose effect can't be read off it: inline code for an interpreter, a nested shell, process
    /// substitution, eval, exec or source. Not destructive by itself, but never worth a rule that allows it again.
    public static func opaque(_ command: String) -> Bool {
        command.range(of: #"\b(python[0-9.]*|perl|ruby|node|deno|bun|php|osascript|lua|(ba|z|da|fi)?sh)\s+(-[a-zA-Z]*[ce]\b|-\s|-$)|<\(|\b(eval|exec|source)\s|(^|[;&|]\s*)\.\s+\S"#,
                      options: .regularExpression) != nil
    }

    /// File paths are judged as written and where they lead, so `notes.txt -> .claude/settings.json` is a settings edit.
    static func assess(_ action: IslandAction, cwd: String? = nil) -> (IslandRisk, String?) {
        func matches(_ pattern: String, _ text: String) -> Bool { text.range(of: "(?m)" + pattern, options: .regularExpression) != nil }
        func matches(_ pattern: String, path: String) -> Bool {
            matches(pattern, path) || matches(pattern, destination(path, cwd: cwd))
        }
        switch action {
        case .command(let command):
            return judged(command, depth: 0).map { (.destructive, $0) } ?? (.normal, nil)
        case .edit(let path, _, _), .write(let path, _):
            if matches(agentConfig, path: path) { return (.destructive, "Changes Claude Code or Codex settings") }
            if matches(runsLater, path: path) { return (.destructive, "Changes what runs by itself later") }
            return matches(secretPaths, path: path) ? (.destructive, "Changes a credentials file") : (.normal, nil)
        case .patch(let files, let text):
            if files.contains(where: { matches(secretPaths, path: $0) }) { return (.destructive, "Changes a credentials file") }
            if files.contains(where: { matches(agentConfig, path: $0) }) { return (.destructive, "Changes Claude Code or Codex settings") }
            if files.contains(where: { matches(runsLater, path: $0) }) { return (.destructive, "Changes what runs by itself later") }
            return text.contains("*** Delete File: ") ? (.destructive, "Deletes files") : (.normal, nil)
        case .read(let path):
            return matches(secretPaths, path: path) ? (.destructive, "Reads a credentials file") : (.low, nil)
        case .search(let text):
            // Grep and Glob read what they match: "aws_secret in ~/.aws" is a read of credentials.
            if matches(secretPaths, text.replacingOccurrences(of: " ", with: "\n")) || matches(#"(^|[\s/])\.(ssh|aws|gnupg|kube)(/|\s|$)"#, text) {
                return (.destructive, "Searches credentials")
            }
            return (.low, nil)
        case .question, .plan:
            return (.low, nil)
        case .fetch, .mcp, .other:
            return (.normal, nil)
        }
    }

    /// Inline code that runs something or reaches for what runs later.
    private static let inlineRuns = #"\brm\b|\bunlink\b|\brmtree\b|\bsystem\s*\(|\bpopen\b|\bsubprocess\b|\bchild_process\b|\bexec[a-z]*\s*\(|\bspawn[a-zA-Z]*\s*\(|\bshell_exec\b|\.git\b|\bhooks\b|\.claude\b|\.codex\b|\.(zshrc|zshenv|zprofile|bashrc|bash_profile|profile)\b|LaunchAgents"#

    /// Why a command needs Face ID, or nil. The rules are advice, not a boundary: they read the raw text and, word by
    /// word, what a shell would make of it. A command that can't be read is held to more, never less.
    private static func judged(_ command: String, depth: Int, cwd start: String? = nil) -> String? {
        func matches(_ pattern: String, _ text: String) -> Bool { text.range(of: "(?m)" + pattern, options: .regularExpression) != nil }
        if let rule = commandRules.first(where: { matches($0.0, command) }) { return rule.1 }
        if matches(#"\s(~/)?\.(ssh|aws|gnupg)/"#, command) { return "Touches credentials" }
        let parsed = ShellWords.parse(command)
        if parsed.unreadable { return "Side A can't read this command" }
        var cwd = start, inCase = false

        func segmentRisk(_ segment: ShellWords.Segment) -> String? {
            let run = ShellWords.command(segment)
            if run.dynamic { return "Side A can't tell what this runs" }
            let name = run.words.first ?? ""
            if name == "case" { inCase = true } else if name == "esac" { inCase = false }
            if !inCase, ShellWords.expands(name) { return "Side A can't read this command" }
            if ShellWords.shells.contains(name), segment.piped || segment.hereInput { return "Runs a script Side A can't read" }
            if !name.isEmpty {
                let text = run.words.joined(separator: " ")
                if let rule = commandRules.first(where: { matches($0.0, text) }) { return rule.1 }
            }
            if name == "git" {
                if segment.words.contains(where: ShellWords.riskyGitEnvironment) { return "Runs code through git's settings" }
                if let reason = ShellWords.gitRisk(run.words) { return reason }
            }
            if depth < 3, let inner = ShellWords.inlineScript(run.words), let reason = judged(inner, depth: depth + 1, cwd: cwd) { return reason }
            if let code = ShellWords.inlineCode(run.words), matches(inlineRuns, code) { return "Runs a command or touches what runs later from inline code" }
            if ShellWords.interpreter(name), segment.piped || segment.hereInput, matches(inlineRuns, command) { return "Runs a command or touches what runs later from inline code" }
            if let found = ShellWords.findCommand(run.words) {
                if let sub = found.first, ShellWords.shells.contains(sub), ShellWords.inlineScript(found) == nil { return "Runs a script Side A can't read" }
                if let reason = segmentRisk(ShellWords.Segment(words: found, dynamic: found.map { $0.contains("$") })) { return reason }
            }
            if name == "cd" || name == "pushd" { cwd = ShellWords.entered(run.words, from: cwd) }
            let here = cwd
            let spots = { (word: String) in ShellWords.pathForms(word).flatMap { ShellWords.placed($0, in: here) } }
            let candidates = (ShellWords.pathWords(run.words) + segment.writes).flatMap(spots)
            if candidates.contains(where: { matches(secretPaths, $0) && !matches(secretTemplates, $0) }) { return "Touches credentials" }
            if candidates.contains(where: { matches(agentConfig, $0) }) { return "Changes Claude Code or Codex settings" }
            let written = ShellWords.onlyReads(run.words) ? segment.writes : ShellWords.pathWords(run.words) + segment.writes
            if written.flatMap(spots).contains(where: { matches(runsLater, $0) }) { return "Changes what runs by itself later" }
            return nil
        }

        for segment in parsed.segments {
            if let reason = segmentRisk(segment) { return reason }
        }
        return nil
    }

    /// Where a path really leads, following every symlink on the way, a last one whose target doesn't exist yet
    /// included (Foundation's resolvingSymlinksInPath gives up on those). A relative path with no cwd stays as it is.
    static func destination(_ path: String, cwd: String?) -> String {
        guard path.hasPrefix("/") || cwd?.hasPrefix("/") == true else { return path }
        var pending = (path.hasPrefix("/") ? path : cwd! + "/" + path).split(separator: "/").map(String.init)
        var resolved: [String] = []
        var hops = 0
        while !pending.isEmpty {
            let part = pending.removeFirst()
            if part == "." { continue }
            if part == ".." { _ = resolved.popLast(); continue }
            let candidate = "/" + (resolved + [part]).joined(separator: "/")
            // 32 hops, as the kernel allows: a loop ends there.
            if hops < 32, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                hops += 1
                if target.hasPrefix("/") { resolved = [] }
                pending = target.split(separator: "/").map(String.init) + pending
                continue
            }
            resolved.append(part)
        }
        return "/" + resolved.joined(separator: "/")
    }
}

public enum IslandAnswer: Sendable, Equatable {
    case allow, always(IslandSuggestion), deny(String?), terminal
    /// Allow, and leave the session in this permission mode (Claude's `setMode` for the session). A destructive
    /// request takes it only as it takes `.allow`: confirmed.
    case allowMode(String)
    /// AskUserQuestion: each question's text mapped to the chosen labels, joined with commas.
    case answers([String: String], input: Data)
    case approvePlan(input: Data, acceptEdits: Bool)

    public var line: Data {
        var object: [String: Any]
        switch self {
        case .allow: object = ["behavior": "allow"]
        case .allowMode(let mode): object = ["behavior": "allow", "mode": mode]
        case .always(let suggestion):
            object = ["behavior": "allow"]
            if let rule = try? JSONSerialization.jsonObject(with: suggestion.json) { object["permissions"] = [rule] }
        case .deny(let message): object = ["behavior": "deny", "message": message ?? "The user denied this in Side A."]
        case .terminal: object = ["behavior": "ask"]
        case .answers(let answers, let input):
            var updated = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
            updated["answers"] = answers
            object = ["behavior": "allow", "input": updated]
        case .approvePlan(let input, let acceptEdits):
            object = ["behavior": "allow", "input": (try? JSONSerialization.jsonObject(with: input)) ?? [String: Any]()]
            if acceptEdits { object["permissions"] = [["type": "setMode", "mode": "acceptEdits", "destination": "session"]] }
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return data + Data("\n".utf8)
    }
}

/// A session that finished its turn with nothing left running in the background.
public struct IslandFinish: Sendable, Equatable {
    public let agent: IslandAgent
    public let sessionID: String?
    public let cwd: String?
    public let pid: Int?
    public let summary: String
    /// The hook keeps waiting in the background, so a follow-up can wake the session.
    public let waits: Bool
    /// `claude -p`, a script or the Agent SDK: nobody is at a prompt to go back to.
    public let headless: Bool

    public var project: String? { cwd.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } }

    public init?(message data: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let request = message["request"] as? [String: Any], request["hook_event_name"] as? String == "Stop" else { return nil }
        agent = IslandAgent(rawValue: message["agent"] as? String ?? "") ?? .claude
        sessionID = request["session_id"] as? String
        cwd = request["cwd"] as? String
        pid = message["pid"] as? Int
        summary = Self.summary(request["last_assistant_message"] as? String ?? "")
        waits = message["wait"] as? Bool ?? false
        headless = message["headless"] as? Bool ?? false
    }

    public init(agent: IslandAgent, sessionID: String?, cwd: String?, pid: Int?, summary: String) {
        self.agent = agent; self.sessionID = sessionID; self.cwd = cwd; self.pid = pid; self.summary = Self.summary(summary); waits = false; headless = false
    }

    /// The reply's first line of prose, without Markdown, short enough for two lines in the island.
    static func summary(_ text: String) -> String {
        // A pipeline's reply is often JSON, whose first line is a lone bracket.
        if let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first, first == "[" || first == "{",
           (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) != nil { return "" }
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.hasPrefix("```") && !$0.hasPrefix("|") && !$0.hasPrefix("---") && $0.contains { $0.isLetter || $0.isNumber } } ?? ""
        var plain = line.replacingOccurrences(of: #"^(#+|[-*>]|\d+\.)\s+"#, with: "", options: .regularExpression)
        for mark in ["**", "__", "`"] { plain = plain.replacingOccurrences(of: mark, with: "") }
        plain = plain.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        return plain.count > 160 ? String(plain.prefix(159)).trimmingCharacters(in: .whitespaces) + "…" : plain
    }
}

/// A Claude Code session as its registry (`~/.claude/sessions/<pid>.json`) last described it.
public struct IslandSession: Sendable, Equatable {
    public let pid: Int
    public let sessionID: String?
    public let status: String
    public let since: Date

    public init(pid: Int, sessionID: String?, status: String, since: Date) {
        self.pid = pid; self.sessionID = sessionID; self.status = status; self.since = since
    }

    /// A flip between two queued prompts isn't an answer.
    public static let settle: TimeInterval = 0.5

    public enum Verdict: Equatable { case open, answered, unsure }

    /// Claude Code keeps the hook running when its own prompt is answered in the terminal, so the registry
    /// says when it was: the session left "waiting" after the request arrived.
    public static func verdict(_ request: IslandRequest, arrived: Date, in sessions: [IslandSession],
                               alive: (Int) -> Bool, now: Date = Date()) -> Verdict {
        if let pid = request.pid, !alive(pid) { return .answered }
        // Codex and headless runs show no prompt of their own while the hook waits.
        guard request.agent == .claude, !request.headless,
              let session = sessions.first(where: { $0.pid == request.pid })
                ?? sessions.first(where: { request.sessionID != nil && $0.sessionID == request.sessionID }),
              session.status != "waiting", session.since > arrived else { return .open }
        return now.timeIntervalSince(session.since) >= settle ? .answered : .unsure
    }
}

/// What Side A sends a session's waiting Stop hook: the user's next task, or a release.
public enum IslandFollowUp {
    public static func line(_ text: String?) -> Data {
        let object: [String: Any] = text.map { ["followUp": $0] } ?? ["cancel": true]
        return ((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)) + Data("\n".utf8)
    }
}
