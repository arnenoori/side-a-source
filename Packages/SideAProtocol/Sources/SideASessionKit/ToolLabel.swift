import Foundation
import SideAProtocol

/// A step as one short sentence: "Ran swift test", "Edited SessionStore.swift", "Searching the web for …".
public struct ToolLabel: Hashable, Sendable {
    public let verb: String
    public let target: String?
    /// The target is a command, a path or a name, and reads best in a fixed-width face.
    public let mono: Bool

    public init(_ tool: TranscriptTool) {
        let running = tool.status == .running
        func pick(_ past: String, _ present: String) -> String { running ? present : past }
        switch tool.action {
        case .command(let command):
            verb = pick("Ran", "Running"); target = command; mono = true
        case .read(let path):
            verb = pick("Read", "Reading"); target = (path as NSString).lastPathComponent; mono = true
        case .edit(let path, _, _):
            verb = pick("Edited", "Editing"); target = (path as NSString).lastPathComponent; mono = true
        case .write(let path, _):
            verb = pick("Wrote", "Writing"); target = (path as NSString).lastPathComponent; mono = true
        case .patch(let files, _):
            verb = pick("Edited", "Editing"); target = files.count == 1 ? (files[0] as NSString).lastPathComponent : "\(files.count) files"; mono = files.count == 1
        case .fetch(let url):
            verb = pick("Fetched", "Fetching"); target = URL(string: url)?.host() ?? url; mono = true
        case .search(let query):
            if tool.name == "Glob" || tool.name == "LS" {
                verb = pick("Listed", "Listing"); target = query; mono = true
            } else if tool.name == "WebSearch" {
                verb = pick("Searched the web for", "Searching the web for"); target = query; mono = false
            } else {
                verb = pick("Searched", "Searching"); target = "\u{201C}\(query.replacingOccurrences(of: " in Sources", with: ""))\u{201D}"; mono = true
            }
        case .mcp(_, let name, _):
            verb = pick("Used", "Using"); target = name; mono = true
        default:
            switch tool.name {
            case "Thinking":
                verb = running ? "Thinking" : "Thought"; target = nil; mono = false
            case "Task", "Agent":
                verb = pick("Asked a subagent to", "Asking a subagent to"); target = tool.summary.lowercasedFirst; mono = false
            case "TodoWrite", "update_plan":
                verb = pick("Updated the plan", "Updating the plan"); target = nil; mono = false
            default:
                verb = pick("Used", "Using"); target = tool.name; mono = true
            }
        }
    }

    public var accessibilityText: String { [verb, target].compactMap { $0 }.joined(separator: " ") }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

extension TranscriptTool {
    /// How long the step ran, once it has ended.
    public var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return endedAt - startedAt
    }
}
