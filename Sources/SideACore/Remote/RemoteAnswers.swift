import CryptoKit
import Foundation
import SideAProtocol

/// The island's answer rules for the phone. The phone sends what it picked; the tool input and rule JSON that go back
/// to the CLI always come from the Mac's own copy of the request.
public enum RemoteAnswers {
    public static let maxText = 2_000

    /// Questions take answers, plans an approval, everything else Allow, and Always when there is a safe rule to keep.
    public static func accepted(_ request: IslandRequest) -> Set<AnswerKind> {
        switch request.action {
        case .question: [.answers, .deny, .terminal]
        case .plan: [.approvePlan, .deny, .terminal]
        default:
            (request.offersAlways ? [.allow, .always, .deny, .terminal] as Set<AnswerKind> : [.allow, .deny, .terminal])
                .union(modes(request).isEmpty ? [] : [.allowMode])
        }
    }

    /// What "Allow and switch mode" may switch to, best first: accept edits, for Claude's own edits that aren't
    /// destructive. Codex takes no mode from a hook, and questions and plans answer otherwise.
    public static func modes(_ request: IslandRequest) -> [PermissionMode] {
        guard request.agent.provider == .claude, request.risk != .destructive else { return [] }
        switch request.action {
        case .edit, .write, .patch: return [.acceptEdits]
        default: return []
        }
    }

    /// First 16 hex of the rule JSON's SHA-256: stable for the request's life, and says nothing about the rule.
    public static func suggestionID(_ suggestion: IslandSuggestion) -> String {
        SHA256.hash(data: suggestion.json).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public enum Refusal: String, Error, Sendable, Equatable {
        case notAllowed = "not_allowed", needsConfirm = "needs_confirm", unknownSuggestion = "unknown_suggestion"
        case unknownOption = "unknown_option", incomplete = "incomplete", tooLong = "too_long"
    }

    /// What the phone must prove for this answer, from the Mac's own view of the request. Denying or handing back needs
    /// nothing; a mode switch or a rule that outlives the answer takes at least an unlocked phone; a permissive mode Face ID.
    public static func needs(_ request: IslandRequest, _ answer: RemoteAnswer, mode: PermissionMode? = nil, gate: AllowGate) -> ConfirmProof {
        switch answer {
        case .deny, .terminal: return .none
        case .allow, .answers, .approvePlan, .always: break
        }
        var needs = ConfirmProof(gate)
        if request.risk == .destructive { needs = .biometric }
        if let mode { needs = max(needs, mode.raises ? .biometric : .unlock) }
        if case .approvePlan(true) = answer { needs = max(needs, .unlock) }
        if case .always(let id) = answer {
            needs = max(needs, .unlock)
            if let rule = request.suggestions.first(where: { suggestionID($0) == id }), setsPermissiveMode(rule) { needs = .biometric }
        }
        return needs
    }

    static func setsPermissiveMode(_ suggestion: IslandSuggestion) -> Bool {
        guard let rule = (try? JSONSerialization.jsonObject(with: suggestion.json)) as? [String: Any], rule["type"] as? String == "setMode" else { return false }
        return PermissionMode(rawValue: rule["mode"] as? String ?? "").raises
    }

    /// The island answer and whether a destructive Allow was confirmed, which `Island.answer(confirmed:)` takes.
    /// `proven` is what the phone's signature showed (ConfirmGate); the phone's own `confirmDestructive` is ignored.
    /// Anything that lets the agent go on needs the gate's level; denying or handing back needs none.
    /// `mode` comes with `.allow` only, and must be one of the request's `modes`; one that `raises` needs Face ID.
    public static func resolve(_ request: IslandRequest, _ answer: RemoteAnswer, mode: PermissionMode? = nil, gate: AllowGate,
                               proven: ConfirmProof) -> Result<(answer: IslandAnswer, confirmed: Bool), Refusal> {
        guard accepted(request).contains(answer.kind) else { return .failure(.notAllowed) }
        if let mode {
            guard case .allow = answer, modes(request).contains(mode) else { return .failure(.notAllowed) }
            if proven < needs(request, answer, mode: mode, gate: gate) { return .failure(.needsConfirm) }
            return .success((.allowMode(mode.rawValue), proven == .biometric))
        }
        if proven < needs(request, answer, gate: gate) { return .failure(.needsConfirm) }
        switch answer {
        case .allow:
            return .success((.allow, proven == .biometric))
        case .always(let id):
            guard gate != .biometric else { return .failure(.notAllowed) }
            guard let suggestion = request.suggestions.first(where: { suggestionID($0) == id }) else { return .failure(.unknownSuggestion) }
            return .success((.always(suggestion), false))
        case .deny(let message):
            let trimmed = message.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxText)) }
            return .success((.deny(trimmed?.isEmpty == false ? trimmed : nil), false))
        case .terminal:
            return .success((.terminal, false))
        case .approvePlan(let acceptEdits):
            return .success((.approvePlan(input: request.input, acceptEdits: acceptEdits), false))
        case .answers(let given):
            guard case .question(let questions) = request.action else { return .failure(.notAllowed) }
            var text: [String: String] = [:]
            for answer in given {
                guard let question = questions.first(where: { $0.question == answer.question }), text[answer.question] == nil else {
                    return .failure(.unknownOption)
                }
                let labels = Set(question.options.map(\.label))
                guard answer.picked.allSatisfy(labels.contains), question.multiSelect || answer.picked.count <= 1,
                      Set(answer.picked).count == answer.picked.count else { return .failure(.unknownOption) }
                guard (answer.other ?? "").count <= maxText else { return .failure(.tooLong) }
                let joined = question.answerText(picked: answer.picked, other: answer.other)
                guard !joined.isEmpty else { return .failure(.incomplete) }
                text[answer.question] = joined
            }
            guard questions.allSatisfy({ text[$0.question] != nil }) else { return .failure(.incomplete) }
            return .success((.answers(text, input: request.input), false))
        }
    }
}

extension AllowGate {
    /// An explicit allowlist, not the risk heuristics: only reads of plainly harmless files and searches inside the project may be
    /// allowed from a locked phone. `projects` are the session's folder and its git root. Every edit, and everything unknown, takes unlock.
    public static func of(_ request: IslandRequest, projects: [String]) -> AllowGate {
        // Judged again now, not only when it arrived: a link changed since then can make the same request destructive.
        if request.risk == .destructive || request.currentRisk == .destructive { return .biometric }
        if request.hidesText { return .unlock }
        let inside = { (path: String) in safe(path, projects: projects, cwd: request.cwd) }
        switch request.action {
        case .search:
            // A web search sends its words out; Grep and Glob read wherever they're pointed, so only the project counts.
            guard request.tool != "WebSearch" else { return .unlock }
            let input = (try? JSONSerialization.jsonObject(with: request.input)) as? [String: Any] ?? [:]
            let path = (input["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? request.cwd ?? ""
            let pattern = input["pattern"] as? String ?? ""
            // Grep showing matching lines reads whatever holds them, credentials included.
            if request.tool == "Grep", input["output_mode"] as? String == "content" { return .unlock }
            let rooted = request.tool == "Glob" && (pattern.hasPrefix("/") || pattern.hasPrefix("~") || pattern.contains(".."))
            return inside(path) && !rooted ? .lockScreen : .unlock
        case .read(let path):
            guard let within = projectPath(path, projects: projects, cwd: request.cwd), plainRead(within) else { return .unlock }
            return .lockScreen
        case .edit, .write, .patch, .command, .mcp, .fetch, .other, .question, .plan: return .unlock
        }
    }

    static func safe(_ path: String, projects: [String], cwd: String?) -> Bool { projectPath(path, projects: projects, cwd: cwd) != nil }

    /// Where a path leads, relative to the project holding it. Nil outside every project, or for a secret.
    static func projectPath(_ path: String, projects: [String], cwd: String?) -> String? {
        guard !path.isEmpty else { return nil }
        let base = cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let full = IslandRisk.destination((path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: path, relativeTo: base))
            .standardizedFileURL.path, cwd: nil)
        // Home and the folders above it are never a project, though a dotfiles repo makes ~ a git root.
        let home = IslandRisk.destination(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path, cwd: nil)
        let roots = projects.filter { !$0.isEmpty && $0 != "/" }.map { IslandRisk.destination(URL(fileURLWithPath: $0).standardizedFileURL.path, cwd: nil) }
            .filter { home != $0 && !home.hasPrefix($0 + "/") }
        guard let root = roots.first(where: { full == $0 || full.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }), !secret(full) else { return nil }
        return String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Keys, credentials and environment files: reading one from a locked phone is never fine.
    static func secret(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let parts = path.lowercased().split(separator: "/")
        if name.hasPrefix(".env") || name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.hasPrefix("id_ecdsa") { return true }
        if ["secret", "credential", "password", "passwd", "token", "service-account", "service_account", "serviceaccount", "private_key", "privatekey", "adminsdk"].contains(where: name.contains) { return true }
        if [".netrc", ".npmrc", ".pypirc", ".pgpass", ".htpasswd", ".dev.vars", ".git-credentials", ".yarnrc.yml", "auth.json", "kubeconfig"].contains(name) { return true }
        if [".pem", ".key", ".p8", ".p12", ".pfx", ".jks", ".keystore", ".keychain", ".keychain-db", ".mobileprovision", ".tfvars", ".tfstate"].contains(where: name.hasSuffix) { return true }
        return parts.contains { [".git", ".ssh", ".aws", ".gnupg", ".kube", ".docker"].contains(String($0)) }
    }

    /// Prose, pictures and source, by what they are called: the only reads a locked phone may allow. Config formats and
    /// plain text hold secrets too often to tell, and nothing inside a hidden folder or named for settings counts.
    static func plainRead(_ within: String) -> Bool {
        let parts = within.lowercased().split(separator: "/").map(String.init)
        guard let name = parts.last, !parts.contains(where: { $0.hasPrefix(".") }) else { return false }
        if ["settings.", "local_settings.", "config.", "wp-config.", "database."].contains(where: name.hasPrefix) { return false }
        return ["md", "markdown", "rst", "adoc", "csv", "tsv", "png", "jpg", "jpeg", "gif", "webp",
                "swift", "py", "js", "jsx", "ts", "tsx", "go", "rs", "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "rb", "css", "scss", "html"]
            .contains((name as NSString).pathExtension)
    }
}
