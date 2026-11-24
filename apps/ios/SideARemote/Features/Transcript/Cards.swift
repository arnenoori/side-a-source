import SideAProtocol
import SideARemoteShared
import SwiftUI

struct CodeBlockView: View {
    let payload: CodePayload
    static let foldAfter = 20

    var body: some View {
        let lines = payload.code.split(separator: "\n", omittingEmptySubsequences: false)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(payload.language ?? "code")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: payload.code)
            }
            .padding(.leading, Space.s)
            .padding(.trailing, Space.xxs)
            .frame(minHeight: 36)
            Divider().opacity(0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                SelectableText(text: AttributedString(lines.prefix(Self.foldAfter).joined(separator: "\n")),
                               style: SelectableText.Style(textStyle: .footnote, monospaced: true, lineSpacing: 2, wraps: false))
                    .padding(Space.s)
            }
            if lines.count > Self.foldAfter {
                NavigationLink(value: Route.code(payload)) {
                    Text("Show all \(lines.count) lines")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { Divider().opacity(0.5) }
            }
        }
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Radius.block, style: .continuous))
        .zoomSource(payload.id)
    }
}

struct CopyButton: View {
    let text: String
    var label = "Copy"
    @State private var copies = 0
    @State private var showsCheck = false

    var body: some View {
        Button(label, systemImage: showsCheck ? "checkmark" : "doc.on.doc") {
            UIPasteboard.general.string = text
            copies += 1
        }
        .labelStyle(IconTarget(size: CGSize(width: 36, height: 36), vertical: 4))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .contentTransition(.symbolEffect(.replace))
        .sensoryFeedback(.success, trigger: copies)
        .task(id: copies) {
            guard copies > 0 else { return }
            showsCheck = true
            try? await Task.sleep(for: .seconds(1.5))
            showsCheck = false
        }
    }
}

struct DiffCard: View {
    let sourceID: String
    let diff: FileDiff
    var sessionID: SessionKey?
    static let maxHunks = 3
    static let maxLines = 40

    init(sourceID: String, diff: FileDiff, sessionID: SessionKey? = nil) { self.sourceID = sourceID; self.diff = diff; self.sessionID = sessionID }
    init(tool: TranscriptTool, diff: FileDiff, sessionID: SessionKey? = nil) {
        self.init(sourceID: "diff-\(tool.id)-\(diff.path)", diff: diff, sessionID: sessionID)
    }

    private var route: Route { .diff(diff, sourceID: sourceID, session: sessionID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: route) {
                DiffHeader(diff: diff)
            }
            .buttonStyle(.plain)
            Divider().opacity(0.5)
            DiffHunks(diff: diff, maxHunks: Self.maxHunks, maxLines: Self.maxLines)
            if diff.hunks.count > Self.maxHunks || diff.hunks.reduce(0, { $0 + $1.lines.count }) > Self.maxLines {
                NavigationLink(value: route) {
                    Text("Show full diff")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Radius.block, style: .continuous))
        .clipShape(.rect(cornerRadius: Radius.block, style: .continuous))
        .zoomSource(sourceID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\((diff.path as NSString).lastPathComponent), \(diff.additions) lines added, \(diff.deletions) removed")
    }
}

struct DiffHeader: View {
    let diff: FileDiff

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text((diff.path as NSString).lastPathComponent).font(.subheadline.weight(.semibold))
                Text(Self.parent(diff.path)).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: Space.xs)
            (Text("+\(diff.additions)").foregroundStyle(.green) + Text(" −\(diff.deletions)").foregroundStyle(.red))
                .font(.footnote.monospaced())
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Space.s)
        .frame(minHeight: 48)
        .contentShape(.rect)
    }

    static func parent(_ path: String) -> String {
        let parts = (path as NSString).deletingLastPathComponent.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }
}

struct DiffHunks: View {
    let diff: FileDiff
    var maxHunks = Int.max
    var maxLines = Int.max
    var wrap = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.hunks.prefix(maxHunks).enumerated()), id: \.offset) { index, hunk in
                if index > 0 {
                    Text("Lines \(hunk.newStart)–\(hunk.newStart + max(hunk.newCount - 1, 0))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(Color(.tertiarySystemFill))
                }
                lines(hunk)
            }
            if diff.truncated, diff.hunks.count <= maxHunks, diff.hunks.reduce(0, { $0 + $1.lines.count }) <= maxLines {
                Label("Cut short", systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background(Color(.tertiarySystemFill))
            }
        }
    }

    @ViewBuilder private func lines(_ hunk: DiffHunk) -> some View {
        HunkLines(lines: Array(Self.number(hunk).prefix(maxLines)), wrap: wrap)
    }

    struct Line: Hashable {
        let old: Int?
        let new: Int?
        let kind: Character
        let text: String
    }

    static func number(_ hunk: DiffHunk) -> [Line] {
        var old = hunk.oldStart, new = hunk.newStart
        return hunk.lines.map { raw in
            let kind = raw.first ?? " "
            let text = String(raw.dropFirst())
            switch kind {
            case "+": defer { new += 1 }; return Line(old: nil, new: new, kind: kind, text: text)
            case "-": defer { old += 1 }; return Line(old: old, new: nil, kind: kind, text: text)
            case "\\": return Line(old: nil, new: nil, kind: kind, text: text)
            default: defer { old += 1; new += 1 }; return Line(old: old, new: new, kind: " ", text: text)
            }
        }
    }
}

/// One hunk's lines. Unwrapped, they scroll sideways in a ScrollView as tall as the lines measure: sized by
/// `fixedSize`, it came out short and cut the last line in half.
private struct HunkLines: View {
    let lines: [DiffHunks.Line]
    let wrap: Bool
    @State private var width: CGFloat = 0
    @State private var height: CGFloat?

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                DiffLineView(line: line, wrap: wrap)
            }
        }
        if wrap {
            content
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                // Each line at its own height, whatever the scroll view is offered, or the bars (maxHeight .infinity)
                // stretch to the measured height and feed it back.
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: width, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if height != $0 { height = $0 } }
            }
            .frame(height: height)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }
}

private struct DiffLineView: View {
    let line: DiffHunks.Line
    let wrap: Bool
    @ScaledMetric(relativeTo: .caption2) private var gutter: CGFloat = 26

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Rectangle().fill(bar).frame(width: 2).frame(maxHeight: .infinity)
            Group {
                Text(line.old.map(String.init) ?? "").frame(width: gutter, alignment: .trailing)
                Text(line.new.map(String.init) ?? "").frame(width: gutter, alignment: .trailing)
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.caption.monospaced())
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap, vertical: false)
                .padding(.leading, Space.xs)
                .padding(.trailing, Space.s)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((line.kind == "+" ? "Added: " : line.kind == "-" ? "Removed: " : "") + line.text)
    }

    private var fill: Color {
        switch line.kind {
        case "+": .green.opacity(0.14)
        case "-": .red.opacity(0.12)
        default: .clear
        }
    }

    private var bar: Color {
        switch line.kind {
        case "+": .green
        case "-": .red
        default: .clear
        }
    }
}

struct FileChip: View {
    let sessionID: SessionKey
    let tool: TranscriptTool
    let path: String
    let bytes: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        NavigationLink(value: Route.file(sessionID, tool, path: path)) {
            HStack(spacing: Space.s) {
                Image(systemName: Self.symbol(ext))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    (Text(stem) + Text(ext.isEmpty ? "" : ".\(ext)").foregroundStyle(.tertiary))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(Formatting.size(bytes)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, Space.s)
            .padding(.trailing, Space.m)
            .padding(.vertical, Space.s)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Radius.inlineCard, style: .continuous))
            .contentShape(.rect(cornerRadius: Radius.inlineCard))
        }
        .buttonStyle(.plain)
        .zoomSource("file-\(tool.id)")
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
            if model.tools.isLive, model.tools.can(.fileRead) {
                ShareLink(item: SharedFile(tools: model.tools, sessionID: SubagentRef(key: sessionID)?.parent ?? sessionID, path: path),
                          preview: SharePreview(name)) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
        .accessibilityLabel("\(name), \(Formatting.size(bytes))")
        .accessibilityHint("Opens the file")
    }

    static func symbol(_ ext: String) -> String {
        switch ext.lowercased() {
        case "md": "text.document"
        case "pdf": "doc.richtext"
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "svg": "photo"
        case "csv", "tsv", "xlsx", "xls", "numbers": "tablecells"
        case "json": "curlybraces"
        case "html", "htm": "globe"
        case "pptx", "ppt", "key": "rectangle.on.rectangle"
        default: "doc"
        }
    }
}

struct ImageTiles: View {
    let sessionID: SessionKey
    let images: [ImageRef]
    var alignment: HorizontalAlignment = .leading
    var height: CGFloat = 220
    var showsNames = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Space.xs) {
                ForEach(images) { image in
                    NavigationLink(value: Route.images(sessionID, images, start: image.id)) {
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            SessionImage(ref: image)
                                .frame(width: height * image.aspect, height: height)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(.rect(cornerRadius: Radius.thumbnail, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
                                .zoomSource("image-\(image.id)")
                            if showsNames, let name = image.name {
                                Text(name).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                                    .frame(maxWidth: height * image.aspect, alignment: .leading)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(image.accessibilityText)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .defaultScrollAnchor(alignment == .trailing ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }
}

extension ImageRef {
    var aspect: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 1 }
        return min(max(CGFloat(width) / CGFloat(height), 0.4), 2)
    }
}


extension ImageRef {
    var accessibilityText: String {
        let source = switch source {
        case .pasted: "Pasted image"
        case .read: "Image from Read"
        case .mcp, .screenshot: "Screenshot"
        default: "Image"
        }
        return [source, name].compactMap { $0 }.joined(separator: ", ")
    }
}

struct UserBubble: View {
    let sessionID: SessionKey
    let message: TranscriptMessage
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .trailing, spacing: Space.xs) {
            bubble
            CutMessageFooter(sessionID: sessionID, message: message)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func highlights(in text: String) -> [NSRange] {
        guard let agent = model.sessions.session(sessionID)?.agent else { return [] }
        return CommandHighlight.ranges(in: text, agent: agent, commands: model.tools.agent(agent)?.commands ?? [])
    }

    private var bubble: some View {
        VStack(alignment: .trailing, spacing: Space.xs) {
            if !message.images.isEmpty {
                ImageTiles(sessionID: sessionID, images: message.images, alignment: .trailing, height: 120, showsNames: false)
            }
            if let text = model.transcripts.text(message, in: sessionID), !text.isEmpty {
                MaxWidthFraction(fraction: 0.8) {
                    SelectableText(text: AttributedString(text), style: SelectableText.Style(lineSpacing: 0, highlights: highlights(in: text)), menu: [
                        .init(title: "Copy", image: "doc.on.doc") { UIPasteboard.general.string = text },
                        .init(title: "Edit & Resend", image: "pencil") { model.transcripts.drafts[sessionID] = text },
                    ])
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.s)
                    .background(Color(.secondarySystemFill), in: .rect(cornerRadius: Radius.userBubble, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(model.transcripts.text(message, in: sessionID) ?? "")")
    }
}

struct MaxWidthFraction: Layout {
    let fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width.map { $0 * fraction }, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width * fraction, height: nil))
        child.place(at: CGPoint(x: bounds.maxX - size.width, y: bounds.minY), proposal: ProposedViewSize(size))
    }
}

struct CutMessageFooter: View {
    let sessionID: SessionKey
    let message: TranscriptMessage
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.transcripts.isCut(message, in: sessionID) {
            Group {
                if model.transcripts.wholeLoad(message, in: sessionID) == .failed {
                    HStack(spacing: Space.xs) {
                        Text("Couldn't load the rest.")
                        Button("Try Again") { model.transcripts.loadWhole(message, in: sessionID, again: true) }
                            .fontWeight(.semibold)
                    }
                } else {
                    HStack(spacing: Space.xs) {
                        ProgressView().controlSize(.mini)
                        Text("Loading the rest…")
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .onAppear { model.transcripts.loadWhole(message, in: sessionID) }
        }
    }
}
