import AppKit
import CryptoKit
import Foundation
import SideACore
import SwiftUI

/// Something a project is run, built or tested with: a named shell command, from `side-a.json` at the top of the
/// repository, or failing that from `package.json`'s scripts.
struct ProjectAction: Equatable, Identifiable {
    let name: String
    let command: String
    var id: String { name }
}

enum ProjectActions {
    static let file = "side-a.json"
    static let most = 50
    /// A file larger than this isn't one of these.
    static let largest = 256 * 1024

    private struct Listed: Decodable {
        struct Entry: Decodable { let name: String; let command: String }
        let actions: [Entry]
    }

    /// `{"actions": [{"name": "Test", "command": "swift test"}]}`. Entries without a name or a command are left out.
    static func parse(_ data: Data) -> [ProjectAction] {
        guard let listed = try? JSONDecoder().decode(Listed.self, from: data) else { return [] }
        return clean(listed.actions.map { ProjectAction(name: $0.name, command: $0.command) })
    }

    /// A package's scripts, each run through the package manager whose lockfile is beside it.
    static func scripts(_ package: Data, manager: String) -> [ProjectAction] {
        guard let object = try? JSONSerialization.jsonObject(with: package) as? [String: Any], let scripts = object["scripts"] as? [String: Any] else { return [] }
        let safe = scripts.keys.filter { $0.range(of: #"^[A-Za-z0-9:_.-]+$"#, options: .regularExpression) != nil && scripts[$0] is String }
        return clean(safe.sorted().map { ProjectAction(name: $0, command: "\(manager) run \($0)") })
    }

    static func manager(lockfiles: Set<String>) -> String {
        if lockfiles.contains("pnpm-lock.yaml") { return "pnpm" }
        if lockfiles.contains("yarn.lock") { return "yarn" }
        if lockfiles.contains("bun.lock") || lockfiles.contains("bun.lockb") { return "bun" }
        return "npm"
    }

    private static func clean(_ actions: [ProjectAction]) -> [ProjectAction] {
        var seen: Set<String> = []
        let kept = actions.compactMap { action -> ProjectAction? in
            let name = action.name.trimmingCharacters(in: .whitespacesAndNewlines), command = action.command.trimmingCharacters(in: .whitespacesAndNewlines)
            // A command is one line: a control character has no place in what is typed into a terminal.
            guard !name.isEmpty, !command.isEmpty, name.count <= 60, command.count <= 2000, seen.insert(name).inserted,
                  !(name + command).unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
            return ProjectAction(name: name, command: command)
        }
        return Array(kept.prefix(most))
    }

    /// The folder's own actions and where they run: its `side-a.json`, else the nearest one above it up to the
    /// repository's top, else its `package.json`.
    static func read(_ folder: String, files: FileManager = .default) -> (actions: [ProjectAction], folder: String) {
        var at = URL(fileURLWithPath: folder).standardizedFileURL
        for _ in 0..<12 {
            if let data = small(at.appendingPathComponent(file), files: files) {
                let found = parse(data)
                if !found.isEmpty { return (found, at.path) }
            }
            if files.fileExists(atPath: at.appendingPathComponent(".git").path) || at.path == "/" { break }
            at = at.deletingLastPathComponent()
        }
        let here = URL(fileURLWithPath: folder)
        guard let package = small(here.appendingPathComponent("package.json"), files: files) else { return ([], folder) }
        let locks = Set(["pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb"].filter { files.fileExists(atPath: here.appendingPathComponent($0).path) })
        return (scripts(package, manager: manager(lockfiles: locks)), folder)
    }

    static let approvedKey = "projectActionsApproved"
    static let approvedKept = 400

    /// What an approval is of: this command, in this folder. A changed command is asked about again.
    static func mark(_ action: ProjectAction, in folder: String) -> String {
        SHA256.hash(data: Data("\(folder)\0\(action.command)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor static func ask(_ action: ProjectAction, _ folder: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Run “\(action.name)”?"
        alert.informativeText = "\(action.command)\n\nIn \(folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")). Side A asks once for each command."
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func small(_ url: URL, files: FileManager) -> Data? {
        guard let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? Int, size <= largest else { return nil }
        return try? Data(contentsOf: url)
    }
}

extension SessionStore {
    /// What the open conversation's project can be run with, read when the conversation is opened.
    var projectActions: [ProjectAction] { openSession?.cwd.flatMap { desk.projectActions[$0]?.actions } ?? [] }

    func loadProjectActions(_ folder: String?) async {
        guard let folder, !store.isDemo else { return }
        let found = await Task.detached { ProjectActions.read(folder) }.value
        if desk.projectActions[folder]?.actions != found.actions || desk.projectActions[folder]?.folder != found.folder {
            desk.projectActions[folder] = found
        }
    }

    /// Runs it in a new terminal tab, in the folder its file is in. The file is read again, so the command run is
    /// the one there now, and a command not run before in that folder is shown first: an agent can write the file.
    func run(_ action: ProjectAction) {
        guard let cwd = openSession?.cwd else { return }
        let found = ProjectActions.read(cwd)
        desk.projectActions[cwd] = found
        guard let now = found.actions.first(where: { $0.name == action.name }) else { return error = "\(action.name) is no longer one of this project's actions." }
        let mark = ProjectActions.mark(now, in: found.folder)
        var approved = desk.prefs.defaults.stringArray(forKey: ProjectActions.approvedKey) ?? []
        if !approved.contains(mark) {
            guard desk.approveRun(now, found.folder) else { return }
            approved = Array((approved + [mark]).suffix(ProjectActions.approvedKept))
            desk.prefs.defaults.set(approved, forKey: ProjectActions.approvedKey)
        }
        open("cd \(Shell.quote(found.folder)) && \(now.command)", bare: now.command, cwd: found.folder, in: resumeTerminal, file: "run-\(mark.prefix(10))")
    }
}

/// The project's actions, beside a conversation's other chips.
struct RunChip: View {
    let model: SessionStore
    var body: some View {
        let actions = model.projectActions
        if !actions.isEmpty {
            Menu {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    Button { model.run(action) } label: {
                        Text(index < 9 ? "\(action.name)   ⌃⌥\(index + 1)" : action.name)
                        Text(action.command)
                    }
                }
            } label: { ChipLabel(symbol: "play", text: "Run") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Run a project action")
        }
    }
}
