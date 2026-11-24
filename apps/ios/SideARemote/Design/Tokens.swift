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
}

extension View {
    /// Grows what answers a tap past what's drawn, by the given amounts, without moving or resizing anything.
    func hitArea(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) -> some View {
        padding(EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing))
            .contentShape(.rect)
            .padding(EdgeInsets(top: -top, leading: -leading, bottom: -bottom, trailing: -trailing))
    }

    func hitArea(horizontal: CGFloat = 0, vertical: CGFloat = 0) -> some View {
        hitArea(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
    }
}

extension View {
    /// Behind a control while what it opened is up, so the menu, strip or sheet visibly belongs to it. In on touch-down,
    /// out a little slower once the thing has gone.
    func pressedBacking(_ shown: Bool, in shape: some Shape) -> some View {
        background {
            shape.fill(Color(.tertiarySystemFill))
                .opacity(shown ? 1 : 0)
                .animation(shown ? Motion.press : .easeOut(duration: 0.2), value: shown)
        }
    }
}

/// An icon-only label in its own frame, whose tap area reaches past it. Inside the label, so the button feels it.
struct IconTarget: LabelStyle {
    var size: CGSize?
    var horizontal: CGFloat = 0
    var vertical: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration)
            .labelStyle(.iconOnly)
            .frame(width: size?.width, height: size?.height)
            .hitArea(horizontal: horizontal, vertical: vertical)
    }
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
    /// Opacity only, so Reduce Motion keeps it as it is.
    static let press = Animation.easeOut(duration: 0.12)
    /// `velocity` is in fractions of the distance left per second, which is what `interpolatingSpring` takes.
    static func settle(_ reduceMotion: Bool, velocity: Double = 0) -> Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .interpolatingSpring(duration: 0.3, bounce: 0, initialVelocity: velocity)
    }
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
