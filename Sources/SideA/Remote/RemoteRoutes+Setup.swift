import Foundation
import SideACore
import SideAProtocol

/// The Mac's setup state for the phone's one-time rows, and what its composer can offer per agent.
extension RemoteRoutes {
    static let setupRoutes: [Route] = [
        Route("GET", "v1/setup", setup),
        Route("GET", "v1/options", options),
    ]

    @Sendable static func setup(_ context: Context) async -> HTTPResponse {
        let push = await MainActor.run { context.controller.push }
        _ = await push.checkRelay()
        let status = await MainActor.run { () -> SetupStatus? in
            guard let store = context.controller.store else { return nil }
            let island = store.island
            let heard = UserDefaults.standard.double(forKey: Island.lastCodexHookKey)
            let codex = !store.isInstalled(.codex) ? "notInstalled" : island.installed[.codex] != true ? "off" : heard > 0 ? "trusted" : "unconfirmed"
            let device = store.remote.devices.devices.first { $0.id == context.device }
            return SetupStatus(claudeHooks: island.installed[.claude] == true, codexHooks: codex, codexLastHeardAt: heard > 0 ? heard : nil,
                               tmux: store.hosted.available ? "ok" : "missing", keepAwake: store.keepAwake.settings.enabled,
                               onPower: store.keepAwake.onPower, relay: store.remote.push.relayState,
                               push: .init(registered: device?.push != nil, lastResult: device?.pushResult))
        }
        return status.map { json(200, $0) } ?? notReady
    }

    @Sendable static func options(_ context: Context) async -> HTTPResponse {
        guard let agents = await RemoteOptions.agents(context.controller) else { return notReady }
        return json(200, OptionsList(agents: agents))
    }
}

/// Side A has no model menu of its own, so the options are what each CLI takes and what this Mac has used: the
/// aliases, then the models in the usage report or Codex's config, then the user's own commands and skills.
enum RemoteOptions {
    typealias Option = AgentOptions.Option

    /// Each agent's models, efforts and commands: the phone's options and the Sessions window's New Session.
    static func agents(_ controller: RemoteController) async -> [AgentOptions]? {
        let known = await MainActor.run { () -> (claude: Bool, codex: String?, used: [String], homes: RemoteOptions.Homes)? in
            guard let store = controller.store else { return nil }
            let used = (store.report?.models ?? []).sorted { $0.total > $1.total }.compactMap(\.model)
            // A demo never runs the real Codex, and reads only its own folders.
            let codex = store.isInstalled(.codex) && !store.isDemo ? store.dependencies.agent(.codex).path : nil
            return (store.isInstalled(.claude), codex, used, homes(store))
        }
        guard let known else { return nil }
        let codexModels = await Self.codexModels(codex: known.codex, home: known.homes.codex)
        let commands = await Self.commands(known.homes, cache: controller.cache)
        return [AgentOptions(agent: .claude, installed: known.claude, models: claudeModels(used: known.used), commands: commands.claude),
                AgentOptions(agent: .codex, installed: known.codex != nil, models: codexModels, commands: commands.codex)]
    }

    /// Where each agent keeps its commands: the user's home, or a demo's own folder; Codex's CODEX_HOME when set.
    struct Homes: Sendable {
        let home: URL
        let codex: URL
    }

    @MainActor static func homes(_ store: AccountStore) -> Homes {
        let home = store.sessions.transcriptSource?.home ?? (store.isDemo ? store.root : FileManager.default.homeDirectoryForCurrentUser)
        return Homes(home: home, codex: ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex"))
    }

    /// Each agent's built-ins, commands and skills, for the phone's options and the Sessions window's suggestions.
    /// Reading every command and skill file is the slow part; a new one shows within half a minute.
    static func commands(_ homes: Homes, cache: RemoteCache) async -> (claude: [Option], codex: [Option]) {
        let commands = try? await cache.value("commands \(homes.home.path) \(homes.codex.path)", ttl: 30) {
            await Task.detached { (claudeCommands(home: homes.home.appendingPathComponent(".claude")), codexCommands(home: homes.codex)) }.value
        }
        return (commands?.0 ?? [], commands?.1 ?? [])
    }

    /// Claude Code's `--effort`: every model takes these; `auto` leaves Claude's own default.
    static let claudeBase: [Effort] = [.auto, .low, .medium, .high]

    /// xhigh and max, except on the models from before them.
    static func claudeEfforts(_ id: String) -> [Effort] {
        let id = id.lowercased()
        let older = id.contains("claude-3") || ["opus-4-0", "opus-4-1", "opus-4-5", "sonnet-4-0"].contains { id.contains($0) }
            || id.range(of: #"(opus|sonnet)-4-\d{8}"#, options: .regularExpression) != nil
        return claudeBase + (older ? [] : [.xhigh, .max])
    }

    static func claudeModels(used: [String]) -> [ModelOption] {
        let aliases = [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")].map { ($0.0, $0.1) }
        let ids = aliases + used.filter { ModelName.provider($0) == .claude && !$0.hasPrefix("<") }.prefix(8).map { ($0, ModelName.short($0)) }
        var seen = Set<String>()
        return ids.filter { seen.insert($0.0).inserted }.map {
            ModelOption(id: $0.0, title: $0.1, agent: .claude, efforts: claudeEfforts($0.0), defaultEffort: .auto, canChangeEffortMidSession: true)
        }
    }

    /// What `codex debug models` lists, each with the levels it takes; none and minimal are never offered.
    struct CodexCatalog: Decodable {
        struct Model: Decodable {
            struct Level: Decodable { let effort: String }
            let slug: String
            let display_name: String?
            let default_reasoning_level: String?
            let supported_reasoning_levels: [Level]?
            let supports_reasoning_effort_updates: Bool?
            let visibility: String?
        }
        let models: [Model]
    }

    static func codexOptions(_ catalog: CodexCatalog) -> [ModelOption] {
        catalog.models.filter { $0.visibility != "hide" }.map { model in
            let efforts = (model.supported_reasoning_levels ?? []).map { Effort(rawValue: $0.effort) }.filter { $0 != .none && $0 != .minimal }
            let fallback = model.default_reasoning_level.map(Effort.init(rawValue:))
            return ModelOption(id: model.slug, title: model.display_name ?? ModelName.short(model.slug), agent: .codex, efforts: efforts,
                               defaultEffort: fallback.flatMap { efforts.contains($0) ? $0 : nil }, canChangeEffortMidSession: model.supports_reasoning_effort_updates)
        }
    }

    private static let cache = Cache()
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var codex: (at: Date, home: URL, models: [ModelOption])?
    }

    /// From Codex itself, kept ten minutes; without it, the model Codex's config names, with no efforts to offer.
    static func codexModels(codex: String?, home: URL) async -> [ModelOption] {
        if let cached = cache.lock.withLock({ cache.codex }), cached.home == home, Date().timeIntervalSince(cached.at) < 600 { return cached.models }
        if let codex {
            let result = await HostedSessions.process(codex, ["debug", "models"], environment: ["CODEX_HOME": home.path], timeout: 20)
            if result.status == 0, let catalog = try? JSONDecoder().decode(CodexCatalog.self, from: Data(result.output.utf8)) {
                let models = codexOptions(catalog)
                cache.lock.withLock { cache.codex = (Date(), home, models) }
                return models
            }
        }
        return configuredCodexModel(home: home).map { [ModelOption(id: $0, title: ModelName.short($0), agent: .codex)] } ?? []
    }

    static func configuredCodexModel(home: URL) -> String? {
        (try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8))?
            .split(separator: "\n").lazy.compactMap { line -> String? in
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, parts[0] == "model" else { return nil }
                return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }.first
    }

    /// A start's effort, checked against the model it runs; nil when it can be run.
    static func refusal(effort: String?, model: String?, agent: AgentProvider, options: [AgentOptions]) -> String? {
        guard let effort, effort != Effort.auto.rawValue || agent == .claude else { return nil }
        let models = options.first { $0.agent == agent }?.models ?? []
        let id = model ?? (agent == .claude ? "opus" : models.first?.id)
        guard let chosen = models.first(where: { $0.id == id }) else {
            // A model not listed: Claude's own efforts, and nothing for Codex, which checks nothing itself.
            return agent == .claude && claudeEfforts(id ?? "").map(\.rawValue).contains(effort) ? nil : "That model doesn't take an effort of \(effort)."
        }
        return chosen.efforts.map(\.rawValue).contains(effort) ? nil : "\(chosen.title) doesn't take an effort of \(effort)."
    }

    static let claudeBuiltIn = [
        ("/compact", "Summarize the conversation to free up context"), ("/clear", "Start over with an empty conversation"),
        ("/review", "Review a pull request"), ("/model", "Choose the model"), ("/effort", "Choose how hard Claude thinks"),
        ("/context", "Show what fills the context"), ("/init", "Write a CLAUDE.md for this project"),
    ].map { Option(id: $0.0, label: $0.1) }

    static let codexBuiltIn = [
        ("/model", "Choose the model and reasoning effort"), ("/compact", "Summarize the conversation to free up context"),
        ("/new", "Start a new conversation"), ("/review", "Review the current changes"), ("/diff", "Show the git diff"),
        ("/status", "Show the session's settings and usage"), ("/init", "Write an AGENTS.md for this project"),
    ].map { Option(id: $0.0, label: $0.1) }

    /// Built-ins, then ~/.claude/commands (a subfolder is a namespace: `/frontend:review`), then skills.
    static func claudeCommands(home: URL) -> [Option] {
        let commands = markdown(in: home.appendingPathComponent("commands"), recursive: true).map { file, name in
            Option(id: "/" + name.replacingOccurrences(of: "/", with: ":"), label: summary(file) ?? "Your command")
        }
        return unique(claudeBuiltIn + commands + skills(in: home.appendingPathComponent("skills"), prefix: "/"))
    }

    /// Built-ins, then Codex's custom prompts, which it runs as `/prompts:<name>`, then its skills, which it runs as
    /// `$<name>`: the user's own, then the ones Codex ships in `skills/.system`.
    static func codexCommands(home: URL) -> [Option] {
        let prompts = markdown(in: home.appendingPathComponent("prompts"), recursive: false).map { file, name in
            Option(id: "/prompts:" + name, label: summary(file) ?? "Your prompt")
        }
        let skills = home.appendingPathComponent("skills")
        return unique(codexBuiltIn + prompts + self.skills(in: skills, prefix: "$") + self.skills(in: skills.appendingPathComponent(".system"), prefix: "$"))
    }

    /// Each `<name>/SKILL.md` in a folder, by name; dot folders are left out.
    private static func skills(in folder: URL, prefix: String) -> [Option] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted().compactMap { name -> Option? in
            let file = folder.appendingPathComponent("\(name)/SKILL.md")
            guard !name.hasPrefix("."), FileManager.default.fileExists(atPath: file.path) else { return nil }
            return Option(id: prefix + name, label: summary(file) ?? "Your skill")
        }
    }

    static let maxCommands = 300

    /// Markdown files under a folder and their names relative to it, without `.md`.
    private static func markdown(in folder: URL, recursive: Bool) -> [(URL, String)] {
        let base = folder.resolvingSymlinksInPath().path + "/"
        guard let walker = FileManager.default.enumerator(at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: nil,
                                                          options: recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }.compactMap { file in
            let path = file.resolvingSymlinksInPath().path
            guard path.hasPrefix(base) else { return nil }
            return (file, String(path.dropFirst(base.count).dropLast(3)))
        }.sorted { $0.1 < $1.1 }
    }

    /// The front matter's `description`, else the first line of text, cut to a row.
    static func summary(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let text = String(decoding: (try? handle.read(upToCount: 8192)) ?? Data(), as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            if let line = lines[1..<end].first(where: { $0.hasPrefix("description:") }) {
                let value = line.dropFirst("description:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if !value.isEmpty { return cut(value) }
            }
            lines = Array(lines[(end + 1)...])
        }
        return lines.first { !$0.isEmpty }.map { cut($0.trimmingCharacters(in: CharacterSet(charactersIn: "# "))) }
    }

    private static func cut(_ text: String) -> String { text.count > 120 ? String(text.prefix(119)) + "…" : text }

    private static func unique(_ options: [Option]) -> [Option] {
        var seen = Set<String>()
        return Array(options.filter { seen.insert($0.id).inserted }.prefix(maxCommands))
    }
}
