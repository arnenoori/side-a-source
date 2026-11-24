import SideARemoteShared
import SwiftUI

struct MarkdownView: View {
    let markdown: String
    var sourceID: String = "md"
    var fading: [FadingWords] = []
    @Environment(\.openFile) private var openFile

    init(_ markdown: String, sourceID: String = "md", fading: [FadingWords] = []) {
        self.markdown = markdown
        self.sourceID = sourceID
        self.fading = fading
    }

    private var blocks: [MarkdownBlock] { MarkdownParser.blocks(markdown, files: openFile != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(blocks) { block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textRenderer(FadingWordsRenderer())
        .privacySensitive()
    }

    private func text(_ block: MarkdownBlock) -> Text {
        guard !fading.isEmpty, block.id == blocks.last?.id else { return Text(block.text) }
        var rest = block.text
        var spans: [(AttributedString, Double)] = []
        for span in fading.reversed() where span.count > 0 {
            let count = rest.characters.count
            let cut = rest.characters.index(rest.startIndex, offsetBy: max(0, count - span.count))
            spans.insert((AttributedString(rest[cut...]), span.opacity), at: 0)
            rest = AttributedString(rest[..<cut])
        }
        return spans.reduce(Text(rest)) { text, span in
            Text("\(text)\(Text(span.0).customAttribute(FadingWords.Opacity(value: span.1)))")
        }
    }

    private func fades(_ block: MarkdownBlock) -> Bool { !fading.isEmpty && block.id == blocks.last?.id }

    @ViewBuilder private func prose(_ block: MarkdownBlock, _ style: SelectableText.Style = .init()) -> some View {
        if fades(block) {
            text(block).font(.body).lineSpacing(3).foregroundStyle(style.secondary ? .secondary : .primary)
        } else {
            SelectableText(text: block.text, style: style)
        }
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            prose(block)
        case .heading(let level):
            prose(block, SelectableText.Style(textStyle: level == 1 ? .title3 : level == 2 ? .headline : .subheadline,
                                              weight: level == 1 ? .bold : .semibold))
                .padding(.top, Space.xs)
                .accessibilityAddTraits(.isHeader)
        case .code(let language):
            CodeBlockView(payload: CodePayload(id: "\(sourceID)-code-\(block.id)", language: language,
                                               code: String(block.text.characters).trimmingCharacters(in: .newlines)))
        case .listItem(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(marker).font(.body.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing)
                prose(block)
            }
            .padding(.leading, CGFloat(depth - 1) * 20)
        case .quote:
            HStack(spacing: Space.s) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(.separator)).frame(width: 3)
                prose(block, SelectableText.Style(secondary: true))
            }
        case .rule:
            Divider().padding(.vertical, Space.xs)
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)
        }
    }
}

struct MarkdownTable: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]
    @Environment(\.openFile) private var openFile

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: Space.xs) {
                GridRow {
                    ForEach(header.indices, id: \.self) { Text(header[$0]).font(.subheadline.weight(.semibold)) }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(rows[row].indices, id: \.self) { Text(rows[row][$0]).font(.subheadline.monospacedDigit()) }
                    }
                }
            }
            .padding(.vertical, Space.xxs)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let path = FileLink.path(url) else { return .systemAction }
            openFile?.open(path)
            return .handled
        })
    }
}

struct FadingWords: Equatable {
    var count: Int
    var opacity: Double

    struct Opacity: TextAttribute { var value: Double }
}

struct FadingWordsRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if let fade = run[FadingWords.Opacity.self] {
                    var faded = context
                    faded.opacity = fade.value
                    faded.draw(run)
                } else {
                    context.draw(run)
                }
            }
        }
    }
}
