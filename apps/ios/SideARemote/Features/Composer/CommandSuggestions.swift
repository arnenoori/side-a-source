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
        CaretWord.command(in: text, caret: caret, codex: agent == .codex)
    }

    /// Options starting with the word first, then those containing it, in the Mac's own order.
    static func matches(_ word: String, in options: [Option]) -> [Option] { CaretWord.matches(word, in: options, limit: limit) }

    /// The text with the word replaced by the chosen command and a space after it, and the caret after that space.
    static func apply(_ option: Option, to text: String, at range: NSRange) -> (text: String, caret: Int) {
        CaretWord.replace(range, in: text, with: option.id)
    }
}

/// The list over the field: each command with its description on one muted line; the highlighted row is the one
/// Return or Tab takes from a hardware keyboard. From L8's draft.
struct CommandSuggestionList: View {
    let options: [AgentOptions.Option]
    let highlighted: Int
    /// The options are paths: each shows its file's name over its folder.
    var files = false
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
                let file = files ? FileMentions.Row(path: option.id) : nil
                Text(file?.name ?? option.id).font(.body.weight(.medium)).truncationMode(files ? .middle : .tail)
                if let detail = file?.folder ?? Optional(option.label), !detail.isEmpty {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).truncationMode(files ? .head : .tail)
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
