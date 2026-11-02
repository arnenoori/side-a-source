import Foundation
import SideAProtocol
import SwiftUI

/// The composer's autocomplete, as the Mac's composer does it: a "/" word at the caret (either agent), or a Codex
/// "$" one, lists the commands and skills the Mac's `/v1/options` names, the user's own included.
enum CommandSuggestions {
    typealias Option = AgentOptions.Option

    /// Rows matched at most, as on the Mac.
    static let limit = 8
    /// How many rows show before the list scrolls.
    static let visibleRows = 5

    /// The word the caret (a UTF-16 offset) is in or just after, when it starts with "/" or, for Codex, "$".
    static func word(in text: String, caret: Int, agent: AgentProvider) -> (range: NSRange, word: String)? {
        let string = text as NSString
        let caret = min(max(caret, 0), string.length)
        var start = caret
        while start > 0, !isSpace(string.character(at: start - 1)) { start -= 1 }
        var end = caret
        while end < string.length, !isSpace(string.character(at: end)) { end += 1 }
        guard start < caret else { return nil }
        let word = string.substring(with: NSRange(location: start, length: end - start))
        guard word.hasPrefix("/") || agent == .codex && word.hasPrefix("$") else { return nil }
        return (NSRange(location: start, length: end - start), word)
    }

    /// Options starting with the word first, then those containing it, in the Mac's own order.
    static func matches(_ word: String, in options: [Option]) -> [Option] {
        let typed = word.lowercased()
        let sigil = typed.prefix(1)
        let mine = options.filter { $0.id.hasPrefix(sigil) }
        let starts = mine.filter { $0.id.lowercased().hasPrefix(typed) }
        let rest = typed.count > 1 ? mine.filter { !$0.id.lowercased().hasPrefix(typed) && $0.id.lowercased().contains(typed.dropFirst()) } : []
        return Array((starts + rest).prefix(limit))
    }

    /// The text with the word replaced by the chosen command and a space after it, and the caret after that space.
    static func apply(_ option: Option, to text: String, at range: NSRange) -> (text: String, caret: Int) {
        let string = text as NSString
        let after = range.location + range.length
        let space = after < string.length && isSpace(string.character(at: after)) ? "" : " "
        let replaced = string.replacingCharacters(in: range, with: option.id + space)
        return (replaced, range.location + (option.id + " ").utf16.count)
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D
    }
}

/// The list over the field: each command with its description on one muted line; the highlighted row is the one
/// Return or Tab takes from a hardware keyboard. From L8's draft.
struct CommandSuggestionList: View {
    let options: [AgentOptions.Option]
    let highlighted: Int
    let onPick: (AgentOptions.Option) -> Void

    @ScaledMetric(relativeTo: .body) private var rowHeight = 52

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        row(option, highlighted: index == highlighted).id(option.id)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.hidden)
            .frame(height: min(CGFloat(options.count), CGFloat(CommandSuggestions.visibleRows) + 0.5) * rowHeight + 12)
            .onChange(of: highlighted) { _, index in
                if options.indices.contains(index) { proxy.scrollTo(options[index].id) }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
        .onAppear { AccessibilityNotification.Announcement(options.count == 1 ? "1 suggestion" : "\(options.count) suggestions").post() }
    }

    private func row(_ option: AgentOptions.Option, highlighted: Bool) -> some View {
        Button { onPick(option) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(option.id).font(.body.weight(.medium))
                if !option.label.isEmpty {
                    Text(option.label).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: rowHeight - 8, alignment: .leading)
            .padding(.horizontal, Space.s)
            .padding(.vertical, 4)
            .background {
                if highlighted { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.tertiarySystemFill)) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label.isEmpty ? option.id : "\(option.id), \(option.label)")
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}
