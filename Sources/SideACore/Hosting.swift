import Foundation

/// The pure half of hosted sessions (docs/remote/hosting.md): what to run, what may be typed,
/// and how to read an agent's screen. The app half drives tmux with these.
public enum Hosting {
    public enum Agent: String, Codable, Sendable { case claude, codex }

    public enum Mode: Equatable, Sendable {
        case new(model: String?)
        case resume(String)
        case fork(String)

        public var resumes: String? { if case .resume(let id) = self { id } else { nil } }
    }

    /// Arguments after the agent's name. A first prompt is not here: the launcher adds it last.
    public static func arguments(_ agent: Agent, _ mode: Mode, images: [String] = []) -> [String] {
        switch (agent, mode) {
        case (.claude, .new(let model)): return model.map { ["--model", $0] } ?? []
        case (.claude, .resume(let id)): return ["--resume", id]
        case (.claude, .fork(let id)): return ["--resume", id, "--fork-session"]
        case (.codex, .new(let model)): return (model.map { ["-m", $0] } ?? []) + (images.isEmpty ? [] : ["-i", images.joined(separator: ",")])
        case (.codex, .resume(let id)): return ["resume", id]
        case (.codex, .fork(let id)): return ["fork", id]
        }
    }

    /// What starts a session in a permission mode (the protocol's PermissionMode), after `arguments`; nil when the agent
    /// can't start in it. Claude takes its own names (2.1.303 reads "default" as manual). Codex starts in its own
    /// config's mode for "default", and only the raises are flags; its plan mode is a collaboration mode, not a flag.
    public static func permissionArguments(_ agent: Agent, mode: String) -> [String]? {
        switch (agent, mode) {
        case (.claude, "default"), (.claude, "plan"), (.claude, "acceptEdits"), (.claude, "auto"), (.claude, "dontAsk"),
             (.claude, "bypassPermissions"): ["--permission-mode", mode]
        case (.codex, "default"): []
        case (.codex, "never"): ["-a", "never"]
        case (.codex, "dangerFullAccess"): ["-s", "danger-full-access"]
        default: nil
        }
    }

    /// Why a phone's first prompt can't be started: a leading dash reads as a flag to anything that misses the `--` the
    /// launcher puts before it.
    public static func promptRefusal(_ prompt: String?) -> String? {
        guard let prompt, prompt.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-") else { return nil }
        return "A first prompt can't start with a dash. Start it with a word."
    }

    /// A first prompt as the launcher's last argument. Claude Code picks subcommands after `--` too, so a lone word
    /// (`update`, `mcp`) gets a trailing space, which keeps it a prompt; the launcher's `$(<file)` strips newlines but not that.
    public static func promptArgument(_ prompt: String) -> String {
        prompt.contains(where: \.isWhitespace) ? prompt : prompt + " "
    }

    /// A model or effort is one word from a short alphabet: it goes on the agent's command line.
    public static func safeOption(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.count <= 100 && !value.hasPrefix("-")
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-._:[]/".unicodeScalars.contains($0) }
    }

    /// The longest first prompt passed as an argument; macOS allows 1 MiB for arguments and environment together.
    public static let promptArgumentLimit = 100_000
    public static let replyLimit = 1 << 20

    /// Text as it may be pasted: LF line ends, no control characters but LF and TAB, at most 1 MiB.
    /// ESC matters most: `ESC [201~` inside a paste would end it and type the rest as keys.
    public static func clean(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var size = 0
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").unicodeScalars {
            let value = scalar.value
            if (value < 0x20 && value != 0x0A && value != 0x09) || value == 0x7F || (0x80..<0xA0).contains(value) { continue }
            size += scalar.utf8.count
            if size > replyLimit { break }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// `send-keys` arguments for a key the phone may send; nil for anything else.
    public static func keyArguments(_ key: String) -> [String]? {
        if key.count == 1, let c = key.first, ("1"..."9").contains(c) || ["y", "n", " "].contains(c) { return ["-l", key] }
        if ["Enter", "Escape", "Tab", "BTab", "Up", "Down", "Left", "Right", "C-c", "C-o", "C-t", "C-r", "C-b"].contains(key) { return [key] }
        return nil
    }

    // MARK: Reading the screen

    /// What the composer holds, read from `capture-pane -p -e` (with colours, so a placeholder,
    /// which both CLIs draw dim, reads as empty).
    public enum Composer: Equatable, Sendable {
        case none
        case empty
        case text(String)
    }

    struct Line {
        let raw: String
        let plain: String
    }

    static func lines(_ screen: String) -> [Line] {
        screen.split(separator: "\n", omittingEmptySubsequences: false).map { Line(raw: String($0), plain: plain(String($0))) }
    }

    /// A capture's lines without their escape sequences.
    public static func plainLines(_ screen: String) -> [String] { lines(screen).map(\.plain) }

    /// The text of a captured line without its escape sequences.
    static func plain(_ raw: String) -> String {
        var out = ""
        var scalars = raw.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\u{1B}" else { out.unicodeScalars.append(scalar); continue }
            guard let kind = scalars.next() else { break }
            if kind == "[" { while let s = scalars.next(), !(0x40...0x7E).contains(s.value) {} }
            else if kind == "]" { while let s = scalars.next(), s != "\u{07}", s != "\u{1B}" {} }
        }
        return out
    }

    /// Claude's composer is the line starting with `❯` and a no-break space; prompts it echoed
    /// and dialog rows use a plain space (checked on 2.1.302). Codex draws `› ` for both the
    /// composer and echoed prompts, so its composer is the last such row that isn't an option.
    public static func composer(_ agent: Agent, screen: String) -> Composer {
        let rows = lines(screen)
        let index: Int?
        let glyph: String
        switch agent {
        case .claude:
            glyph = "❯\u{00A0}"
            index = rows.lastIndex { $0.plain.hasPrefix(glyph) }
        case .codex:
            glyph = "› "
            index = rows.lastIndex { $0.plain.hasPrefix(glyph) && !isOption(String($0.plain.dropFirst(2))) }
        }
        guard let index else { return .none }
        let row = rows[index]
        if dimAfterGlyph(row.raw, glyph: glyph) { return .empty }
        // Only the glyph row: the start of what was sent is enough to tell it apart, and every check reads the same row.
        let text = String(row.plain.dropFirst(glyph.count)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? .empty : .text(text)
    }

    static func isOption(_ text: String) -> Bool {
        let digits = text.prefix { $0.isNumber }
        return !digits.isEmpty && text.dropFirst(digits.count).hasPrefix(". ")
    }

    /// True when the first visible text after the glyph is drawn dim (SGR 2): a placeholder.
    static func dimAfterGlyph(_ raw: String, glyph: String) -> Bool {
        // The glyph itself, not glyph and space: Codex puts an escape sequence between them.
        guard let mark = glyph.first, let start = raw.firstIndex(of: mark) else { return false }
        let range = start..<raw.index(after: start)
        var dim = false
        var rest = Substring(raw[range.upperBound...])
        while let first = rest.first {
            if first == "\u{1B}", rest.dropFirst().first == "[" {
                let body = rest.dropFirst(2)
                guard let end = body.firstIndex(where: { ("@"..."~").contains($0) }) else { return false }
                if body[end] == "m" {
                    let codes = body[..<end].split(separator: ";").map(String.init)
                    if codes.isEmpty || codes.contains("0") || codes.contains("22") { dim = false }
                    if codes.contains("2") { dim = true }
                }
                rest = body[body.index(after: end)...]
            } else if first == " " || first == "\u{00A0}" {
                rest = rest.dropFirst()
            } else {
                return dim
            }
        }
        return false
    }

    /// A selection is on screen, so Enter would confirm an option: Claude's `  ❯ 1. Yes`, its trust
    /// question, or Codex's `› 1. Trust and continue`.
    public static func dialog(_ agent: Agent, screen: String) -> Bool {
        lines(screen).suffix(30).contains { line in
            let text = line.plain.trimmingCharacters(in: .whitespaces)
            switch agent {
            case .claude: return text.hasPrefix("❯ ") && isOption(String(text.dropFirst(2))) || text.hasSuffix("Yes, I trust this folder")
            case .codex: return line.plain.hasPrefix("› ") && isOption(String(line.plain.dropFirst(2)))
            }
        }
    }

    public enum Trust: Equatable, Sendable { case trustSelected, otherSelected }

    /// The folder-trust question before a new session's composer. Claude (2.1.302) asks "Is this a
    /// project you created or one you trust?" with `❯ No, exit` selected; Codex selects
    /// `› 1. Trust and continue`. Enter is safe only on `.trustSelected`.
    public static func trust(_ agent: Agent, screen: String) -> Trust? {
        let rows = lines(screen).map { $0.plain.trimmingCharacters(in: .whitespaces) }
        switch agent {
        case .claude:
            guard let row = rows.first(where: { $0.hasSuffix("Yes, I trust this folder") }) else { return nil }
            return row.hasPrefix("❯") ? .trustSelected : .otherSelected
        case .codex:
            guard let row = rows.first(where: { $0.hasSuffix("Trust and continue") }) else { return nil }
            return row.hasPrefix("›") ? .trustSelected : .otherSelected
        }
    }

    /// The folder Claude's trust question names: the row under "Accessing workspace:" (2.1.303). Nil without one.
    public static func trustFolder(screen: String) -> String? {
        let rows = lines(screen).map { $0.plain.trimmingCharacters(in: .whitespaces) }
        guard let at = rows.firstIndex(of: "Accessing workspace:") else { return nil }
        return rows[(at + 1)...].first { !$0.isEmpty }
    }

    /// The composer is up and the CLI has drawn its footer.
    public static func ready(_ agent: Agent, screen: String) -> Bool {
        guard composer(agent, screen: screen) != .none, !dialog(agent, screen: screen) else { return false }
        switch agent {
        // 2.1.303 in manual mode shows only "⏸ manual mode on", without the shift+tab hint.
        case .claude: return screen.contains("shift+tab") || screen.contains("? for shortcuts") || claudeMode(screen: screen) != nil
        case .codex: return true
        }
    }

    /// Claude's footer words for each permission mode (2.1.303), as the protocol's PermissionMode raw values.
    static let claudeModes = [("manual mode on", "default"), ("accept edits on", "acceptEdits"), ("plan mode on", "plan"),
                              ("auto mode on", "auto"), ("bypass permissions on", "bypassPermissions"), ("don't ask on", "dontAsk")]

    /// The permission mode Claude's footer, below its composer, shows; nil without a composer or a footer that names one.
    public static func claudeMode(screen: String) -> String? {
        let rows = lines(screen)
        guard let composer = rows.lastIndex(where: { $0.plain.hasPrefix("❯\u{00A0}") }) else { return nil }
        for row in rows[(composer + 1)...] {
            if let (_, mode) = claudeModes.first(where: { row.plain.contains($0.0) }) { return mode }
        }
        return nil
    }

    // MARK: Claude's model picker and effort slider

    /// Slash commands Side A types into a hosted Claude itself (`HostedSessions.command`).
    public static let typedCommands: Set<String> = ["/compact"]

    /// The command Claude's slash-command list highlights above the composer (`  ❯ /model   Set the AI model…`, a plain
    /// space after the glyph, indented, its description in a column of its own); Enter runs that one, whatever was
    /// typed. Prompts echoed in the conversation start at the margin and have no description. Nil when no list is open.
    public static func slashSuggestion(screen: String) -> String? {
        for row in lines(screen) where row.plain.hasPrefix("  ❯ /") {
            let text = row.plain.dropFirst(4)
            guard let command = text.split(separator: " ").first, text.dropFirst(command.count).hasPrefix("   ") else { continue }
            return String(command)
        }
        return nil
    }

    /// Claude's efforts in the order its slider and picker step through them.
    public static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]

    /// What `/model`'s picker shows (2.1.303): the highlighted row's number and label ("Opus 5.5", "Default
    /// (recommended)") and the effort under the list, nil when the model takes none. Nil when the picker isn't on screen.
    public static func modelPicker(screen: String) -> (row: Int, label: String, effort: String?)? {
        let rows = lines(screen).map(\.plain)
        guard rows.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Select model" }),
              rows.contains(where: { $0.contains("s to use this session only") }) else { return nil }
        var label: String?, number = 0
        for row in rows {
            let text = row.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("❯ "), isOption(String(text.dropFirst(2))) else { continue }
            number = Int(text.dropFirst(2).prefix { $0.isNumber }) ?? 0
            let rest = text.dropFirst(2).drop { $0.isNumber }.dropFirst().drop { $0 == " " }
            // The label ends where the description's column starts: two spaces or more.
            let name = rest.components(separatedBy: "  ").first ?? ""
            label = name.replacingOccurrences(of: " ✔", with: "").trimmingCharacters(in: .whitespaces)
        }
        guard let label, !label.isEmpty else { return nil }
        let effort = rows.lazy.compactMap { row -> String? in
            guard let range = row.range(of: " effort", options: .caseInsensitive), row.contains("←/→") else { return nil }
            let word = row[..<range.lowerBound].split(separator: " ").last.map { String($0).lowercased() } ?? ""
            return claudeEfforts.contains(word) ? word : nil
        }.first
        return (number, label, effort)
    }

    /// The level `/effort`'s slider points at: the label under its ▲. Nil when the slider isn't on screen.
    public static func effortSlider(screen: String) -> String? {
        let rows = lines(screen).map(\.plain)
        guard rows.contains(where: { $0.contains("s for this session only") }),
              let pointer = rows.firstIndex(where: { $0.contains("▲") }), pointer + 1 < rows.count else { return nil }
        let at = Array(rows[pointer]).firstIndex(of: "▲")!
        let names = Array(rows[pointer + 1])
        var best: (String, Int)?
        for level in claudeEfforts {
            // Each label stands alone in the row: "low     medium     high     xhigh      max".
            guard let start = (0..<names.count).first(where: { i in
                String(names[i..<min(names.count, i + level.count)]) == level
                    && (i == 0 || names[i - 1] == " ") && (i + level.count == names.count || names[i + level.count] == " ")
            }) else { return nil }
            let distance = abs(start + level.count / 2 - at)
            if best == nil || distance < best!.1 { best = (level, distance) }
        }
        return best?.0
    }

    public enum SwitchConfirm: Equatable, Sendable {
        /// "Switch model?" or "Change effort level?" for the warm cache, with "Yes, switch to <target>" selected.
        case yesSelected(target: String)
        /// A PreModelSwitch hook asks, or the selection isn't Yes: someone at the Mac decides.
        case other
    }

    /// The confirm Claude shows after a pick when a switch would re-read a cached conversation. Nil when none is open.
    public static func switchConfirm(screen: String) -> SwitchConfirm? {
        let rows = lines(screen).map { $0.plain.trimmingCharacters(in: .whitespaces) }
        guard rows.contains("Switch model?") || rows.contains("Change effort level?") else { return nil }
        if rows.contains(where: { $0.hasPrefix("A PreModelSwitch hook") }) { return .other }
        guard let yes = rows.first(where: { $0.hasPrefix("❯ 1. Yes, switch to ") }) else { return .other }
        return .yesSelected(target: String(yes.dropFirst("❯ 1. Yes, switch to ".count)))
    }

    /// Which picker rows a model id stands for: "default" for Default, an alias ("sonnet") for any of that family's
    /// (the caller takes the first, the newest), a full id for its display name ("claude-sonnet-5-5" is "Sonnet 5.5"). Nil for what the picker
    /// can't pick, such as a 1M variant.
    public static func pickerMatch(_ model: String) -> ((String) -> Bool)? {
        let id = model.lowercased()
        guard !id.isEmpty, !id.contains("["), !id.contains(" ") else { return nil }
        if id == "default" { return { $0.hasPrefix("Default") } }
        let families = ["opus", "sonnet", "haiku", "fable"]
        if families.contains(id) { return { $0.lowercased().hasPrefix(id + " ") } }
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init).filter { $0.count < 8 }
        guard let family = parts.first, families.contains(family), parts.count > 1 else { return nil }
        let name = family.capitalized + " " + parts.dropFirst().joined(separator: ".")
        return { $0 == name }
    }

    // MARK: Pressing Enter again

    static func squash(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    /// What the composer showed right after Side A pasted `sent`, when it can only be Side A's:
    /// its start, or a paste placeholder for long or multi-line text. The result is recorded and
    /// later compared character for character; nil when unclear.
    public static func owned(sent: String, composer: Composer) -> String? {
        guard case .text(let whole) = composer else { return nil }
        let shown = withoutAttachments(whole)
        let squashed = squash(shown), mine = squash(sent)
        guard !mine.isEmpty else { return nil }
        if squashed.hasPrefix(String(mine.prefix(24))) && (mine.count >= 24 || squashed == mine) { return whole }
        let long = sent.count > 200 || sent.contains("\n")
        if long && (shown.hasPrefix("[Pasted text #") || shown.hasPrefix("[Pasted Content ")) { return whole }
        return nil
    }

    /// The text after the photos pasted ahead of it: their quoted paths as typed, or the chips Claude turns them into
    /// a moment later, so a reply with photos is recognized before and after.
    static func withoutAttachments(_ composer: String) -> String {
        composer.replacingOccurrences(of: #"^(\[Image #\d+\]\s*|'[^']+\.(png|jpe?g|gif|webp|heic|heif)'\s*)+"#, with: "",
                                      options: [.regularExpression, .caseInsensitive])
    }

    public enum Verdict: Equatable, Sendable {
        case pressEnter
        /// The prompt went in.
        case taken
        /// No composer: never press Enter blind.
        case stop
        /// It may not have been sent; the user decides (hosted.attention kind "unsent").
        case unsent
    }

    /// A re-press happens only while the composer shows exactly what was recorded after the paste
    /// and no selection is open. Empty means the prompt went in. Anything else is ambiguous.
    public static func verdict(_ agent: Agent, expected: String, screen: String) -> Verdict {
        // An update or permission prompt can sit below an empty-looking composer (Codex 0.156).
        if dialog(agent, screen: screen) { return .unsent }
        switch composer(agent, screen: screen) {
        case .none: return .stop
        case .empty: return .taken
        case .text(let text): return text == expected || withoutAttachments(text) == withoutAttachments(expected) ? .pressEnter : .unsent
        }
    }

    /// Seconds after a send at which the composer is checked again.
    public static let verifySchedule: [Double] = [2, 5, 10, 20, 30, 60]
}
