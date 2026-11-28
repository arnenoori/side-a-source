import Foundation
import SideAProtocol
import SideASessionKit
import SwiftUI

struct CommandSuggestionList: View {
    let options: [AgentOptions.Option]
    let highlighted: Int
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
