import SwiftUI
import UIKit

/// What the key bar drives: the terminal view behind it.
@MainActor
protocol KeyBarKeys: AnyObject {
    var applicationCursor: Bool { get }
    var control: Bool { get set }
    func key(_ bytes: [UInt8])
    func hideKeyboard()
}

/// The keys a phone keyboard lacks, as glass capsules riding it: Esc, a sticky Control,
/// Tab, the arrows (they repeat on hold), ⌃C, the shell's punctuation, and hide the keyboard.
struct KeyBar: View {
    let keys: any KeyBarKeys
    @State private var control = false
    @State private var taps = 0

    private static let controlReset = Notification.Name("SwiftTerm.TerminalView.controlModifierReset")

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    key("esc", label: "Escape") { keys.key([0x1b]) }
                    Button {
                        control.toggle()
                        keys.control = control
                        taps += 1
                    } label: {
                        KeyCap(text: "ctrl", lit: control)
                    }
                    .accessibilityLabel("Control")
                    .accessibilityValue(control ? "On" : "Off")
                    .accessibilityAddTraits(.isToggle)
                    key("tab", label: "Tab") { keys.key([0x09]) }
                    arrow("↑", label: "Up", normal: [0x1b, 0x5b, 0x41], app: [0x1b, 0x4f, 0x41])
                    arrow("↓", label: "Down", normal: [0x1b, 0x5b, 0x42], app: [0x1b, 0x4f, 0x42])
                    arrow("←", label: "Left", normal: [0x1b, 0x5b, 0x44], app: [0x1b, 0x4f, 0x44])
                    arrow("→", label: "Right", normal: [0x1b, 0x5b, 0x43], app: [0x1b, 0x4f, 0x43])
                    key("⌃C", label: "Control C") { keys.key([0x03]) }
                    key("/", label: "Slash") { keys.key(Array("/".utf8)) }
                    key("|", label: "Pipe") { keys.key(Array("|".utf8)) }
                    key("~", label: "Tilde") { keys.key(Array("~".utf8)) }
                    Button { keys.hideKeyboard() } label: {
                        KeyCap(symbol: "keyboard.chevron.compact.down")
                    }
                    .accessibilityLabel("Hide keyboard")
                }
                .padding(.horizontal, Space.xs)
                .padding(.vertical, 6)
            }
        }
        .scrollIndicators(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        // The bar has one row's height above the keyboard.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .sensoryFeedback(.selection, trigger: taps)
        .onReceive(NotificationCenter.default.publisher(for: Self.controlReset)) { _ in control = false }
    }

    private func key(_ text: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            taps += 1
        } label: {
            KeyCap(text: text)
        }
        .accessibilityLabel(label)
    }

    private func arrow(_ text: String, label: String, normal: [UInt8], app: [UInt8]) -> some View {
        RepeatingKey(text: text) {
            keys.key(keys.applicationCursor ? app : normal)
            taps += 1
        }
        .accessibilityLabel(label)
    }
}

private struct KeyCap: View {
    var text: String?
    var symbol: String?
    var lit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let symbol { Image(systemName: symbol) } else { Text(text ?? "") }
        }
        .font(.system(.callout, design: .monospaced).weight(.medium))
        .frame(minWidth: 40, minHeight: 36)
        .padding(.horizontal, 4)
        .foregroundStyle(lit ? Color.black : Color.white)
        .background { if lit { Capsule().fill(.white).transition(.opacity) } }
        // A latched Control answers the tap with its fill alone; the bar's tick is the only haptic.
        .animation(Motion.snappy(reduceMotion), value: lit)
        .glassEffect(.regular.interactive(), in: .capsule)
        .contentShape(.capsule)
    }
}

/// A key that fires on touch down and repeats while held, like the keyboard's own.
private struct RepeatingKey: View {
    let text: String
    let action: () -> Void
    @State private var held: Task<Void, Never>?

    var body: some View {
        KeyCap(text: text)
            .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 30) {} onPressingChanged: { pressing in
                held?.cancel()
                guard pressing else { return }
                action()
                held = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    while !Task.isCancelled {
                        action()
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}
