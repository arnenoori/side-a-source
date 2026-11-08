import SideAProtocol
import SwiftUI

// Surfaces and text use system colours only; the few custom
// colours live in the asset catalog with light, dark and high-contrast variants.

extension Color {
    /// Fills that mean "needs you": the glyph, the Allow tint, ring fills at 75–96%. Never the accent the user picks.
    static let amber = Color("Amber")
    /// Amber text on plain backgrounds, 4.5:1 in both appearances.
    static let amberText = Color("AmberText")
    static let done = Color.green
    static let destructive = Color.red
    static let lcdPlate = Color("LCDPlate")
    static let terminalBackground = Color("TerminalBackground")
    static let terminalForeground = Color("TerminalForeground")
}

extension ShapeStyle where Self == Color {
    static var amber: Color { .amber }
    static var amberText: Color { .amberText }
}

/// The 4 pt grid.
enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Corner radii, all continuous.
enum Radius {
    static let userBubble: CGFloat = 20
    static let questionCard: CGFloat = 20
    static let inlineCard: CGFloat = 14
    static let letterBadge: CGFloat = 6
    static let block: CGFloat = 12
    static let thumbnail: CGFloat = 10
}

/// System curves only. Every custom `withAnimation` goes through here so Reduce
/// Motion turns it into a short fade.
enum Motion {
    static func smooth(_ reduceMotion: Bool) -> Animation { reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.35) }
    static func snappy(_ reduceMotion: Bool) -> Animation { reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.25) }
    /// Rows moving between sections, which travel farther.
    static func move(_ reduceMotion: Bool) -> Animation { reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.45) }
}

extension AgentProvider {
    /// Claude and Codex differ by glyph, never by colour.
    var symbol: String { self == .claude ? "asterisk" : "chevron.left.forwardslash.chevron.right" }
}

/// Glyphs per tool.
enum ToolGlyph {
    static func symbol(for name: String) -> String {
        switch name {
        case "Read": "doc.text"
        case "Write": "doc.badge.plus"
        case "Edit", "MultiEdit", "apply_patch": "pencil.line"
        case "Bash", "exec_command", "shell": "apple.terminal"
        case "Grep": "magnifyingglass"
        case "Glob", "LS": "folder.badge.questionmark"
        case "WebFetch": "globe"
        case "WebSearch": "globe.badge.chevron.backward"
        case "Task", "Agent": "person.2"
        case "TodoWrite", "update_plan": "checklist"
        case "ExitPlanMode": "list.bullet.clipboard"
        case "AskUserQuestion": "questionmark.bubble"
        case "Thinking": "brain"
        case "Screenshot": "photo"
        default: name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}
