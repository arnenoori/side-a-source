import SideAProtocol
import SideASessionKit
import SideARemoteShared
import SwiftUI
import UniformTypeIdentifiers

struct ToolStepPage: View {
    let sessionID: SessionKey
    let tool: TranscriptTool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                content
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemBackground))
        .navigationTitle(ToolLabel(tool).accessibilityText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Image(systemName: ToolGlyph.symbol(for: tool.name)).foregroundStyle(.secondary)
                    Text(ToolLabel(tool).verb).font(.headline)
                }
            }
            if let output = tool.output {
                ToolbarItemGroup(placement: .bottomBar) {
                    CopyAllButton(text: output)
                    Spacer()
                    ShareLink(item: output) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch tool.action {
        case .command(let command):
            MonoBlock(text: "$ " + command, prominent: true)
            if tool.status == .running {
                Label("Running…", systemImage: "progress.indicator")
                    .font(.footnote).foregroundStyle(.secondary)
                    .symbolEffect(.rotate, options: .repeat(.continuous))
            }
            if let output = tool.output { ConsoleLog(text: output, failed: tool.status == .failed) }
        case .read(let path):
            PathLine(path: path)
            if let output = tool.output { ConsoleLog(text: output, failed: false) } else { EmptyOutput() }
        case .edit, .write, .patch:
            ForEach(tool.diffs, id: \.path) { diff in
                VStack(alignment: .leading, spacing: 0) {
                    DiffHeader(diff: diff)
                    Divider().opacity(0.5)
                    DiffHunks(diff: diff)
                }
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Radius.block, style: .continuous))
                .clipShape(.rect(cornerRadius: Radius.block, style: .continuous))
            }
        case .search(let query):
            MonoBlock(text: query, prominent: true)
            if let output = tool.output { GroupedMatches(output: output) } else { EmptyOutput() }
        case .fetch(let url):
            MonoBlock(text: url, prominent: true)
            if let output = tool.output { Text(output).font(.body).textSelection(.enabled) } else { EmptyOutput() }
        case .mcp(let server, let name, let arguments):
            LabeledBlock(title: "\(server) · \(name)", text: arguments)
            if !tool.images.isEmpty { ImageTiles(sessionID: sessionID, images: tool.images) }
            if let output = tool.output { LabeledBlock(title: "Output", text: output) }
        default:
            if tool.name == "Thinking" {
                Text(tool.output ?? "").font(.body).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text(tool.summary).font(.body)
                if let output = tool.output { ConsoleLog(text: output, failed: tool.status == .failed) } else { EmptyOutput() }
            }
        }
        if let duration = tool.duration, let text = Formatting.duration(duration, exact: true) {
            Text(tool.status == .failed ? "Failed after \(text)" : "Took \(text)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
    }
}

private struct CopyAllButton: View {
    let text: String
    @State private var copies = 0

    var body: some View {
        Button("Copy All", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = text
            copies += 1
        }
        .sensoryFeedback(.success, trigger: copies)
    }
}

struct MonoBlock: View {
    let text: String
    var prominent = false

    var body: some View {
        Text(text)
            .font(prominent ? .callout.monospaced().weight(.medium) : .footnote.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.s)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Radius.block, style: .continuous))
    }
}

struct ConsoleLog: View {
    let text: String
    let failed: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.footnote.monospaced())
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.vertical, Space.xs)
        }
        .overlay(alignment: .leading) {
            if failed { Rectangle().fill(Color.destructive).frame(width: 2).offset(x: -Space.xs) }
        }
    }
}

private struct PathLine: View {
    let path: String

    var body: some View {
        Text(path.abbreviatingHome)
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}

private struct LabeledBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            MonoBlock(text: text)
        }
    }
}

struct GroupedMatches: View {
    let output: String

    var body: some View {
        let groups = Self.group(output)
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(groups, id: \.file) { group in
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Label((group.file as NSString).lastPathComponent, systemImage: "doc.text")
                        .font(.subheadline.weight(.semibold))
                    Text(group.file).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    if !group.lines.isEmpty {
                        Text(group.lines.map { "line \($0)" }.joined(separator: " · "))
                            .font(.footnote.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    static func group(_ output: String) -> [(file: String, lines: [String])] {
        var order: [String] = []
        var lines: [String: [String]] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard let file = parts.first else { continue }
            if lines[file] == nil { order.append(file); lines[file] = [] }
            if parts.count > 1 { lines[file]?.append(parts[1]) }
        }
        return order.map { ($0, lines[$0] ?? []) }
    }
}

private struct EmptyOutput: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Text("\(model.mac.kind.sentenceThe(model.mac.name)) didn't keep this step's output.")
            .font(.footnote)
            .foregroundStyle(.tertiary)
    }
}

struct DiffPage: View {
    let diff: FileDiff
    var sessionID: SessionKey?
    @Environment(AppModel.self) private var model
    @State private var wrap = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DiffHunks(diff: diff, wrap: wrap)
            }
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Radius.block, style: .continuous))
            .clipShape(.rect(cornerRadius: Radius.block, style: .continuous))
            .padding(Space.m)
        }
        .navigationTitle((diff.path as NSString).lastPathComponent)
        .navigationSubtitle("+\(diff.additions) −\(diff.deletions)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle("Wrap", systemImage: "text.word.spacing", isOn: $wrap)
            }
            if let sessionID, diff.change != .deleted, model.tools.isLive, model.tools.can(.fileRead) {
                ToolbarItem(placement: .bottomBar) {
                    NavigationLink(value: Route.file(sessionID, nil, path: diff.path)) { Label("Open File", systemImage: "doc.text") }
                }
            }
        }
    }
}

struct CodePage: View {
    let payload: CodePayload
    @State private var wrap = false

    var body: some View {
        ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
            Text(payload.code)
                .font(.callout.monospaced())
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: !wrap, vertical: false)
                .padding(Space.m)
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
        }
        .navigationTitle(payload.language ?? "Code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle("Wrap", systemImage: "text.word.spacing", isOn: $wrap)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                CopyAllButton(text: payload.code)
                Spacer()
                ShareLink(item: payload.code) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
    }
}

struct FilePage: View {
    @Environment(AppModel.self) private var model
    let sessionID: SessionKey
    let tool: TranscriptTool?
    let path: String
    @State private var loaded: (url: URL, kind: FileKind)?
    @State private var failure: String?
    @State private var attempt = 0

    private var name: String { (path as NSString).lastPathComponent }
    private var folder: String {
        (path as NSString).deletingLastPathComponent.split(separator: "/").suffix(2).joined(separator: "/")
    }
    private var sourceID: String { "file-\(tool?.id ?? path)" }
    private var markdown: Bool { ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()) }

    private var inline: String? {
        if model.isDemo, let text = DemoFiles.text(for: path) { return text }
        guard let tool else { return nil }
        if case .write(_, let content) = tool.action { return content }
        return tool.output
    }

    private var showsImage: Bool { if case .image? = loaded?.kind { true } else { false } }

    private var text: String? {
        switch loaded?.kind {
        case .markdown(let text)?, .text(let text)?: text
        case .image?, .quickLook?: nil
        case nil: inline
        }
    }

    var body: some View {
        content
            .navigationTitle(name)
            .navigationSubtitle(folder)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !showsImage {
                    ToolbarItemGroup(placement: .bottomBar) {
                        if let text { CopyAllButton(text: text) }
                        Spacer()
                        if let loaded {
                            ShareLink(item: loaded.url) { Label("Share", systemImage: "square.and.arrow.up") }
                        } else if let inline {
                            ShareLink(item: inline) { Label("Share", systemImage: "square.and.arrow.up") }
                        }
                    }
                }
            }
            .fileLinks(sessionID)
            .task(id: "\(path)#\(attempt)") { if loaded == nil { await load() } }
    }

    @ViewBuilder private var content: some View {
        switch loaded?.kind {
        case .image(let ref)?: ImageViewer(images: [ref], start: ref.id, zooms: false)
        case .quickLook?: if let url = loaded?.url { QuickLookView(url: url).ignoresSafeArea(edges: .bottom) }
        case .markdown(let text)?: ScrollView { MarkdownView(text, sourceID: sourceID).padding(Space.m) }
        case .text(let text)?: ScrollView { Text(text).font(.callout.monospaced()).textSelection(.enabled).padding(Space.m) }
        case nil: placeholder
        }
    }

    @ViewBuilder private var placeholder: some View {
        if let inline {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s) {
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if markdown { MarkdownView(inline, sourceID: sourceID) } else { Text(inline).font(.callout.monospaced()).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.m)
            }
        } else if let reason = failure {
            ContentUnavailableView {
                Label("Can't Open \(name)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(reason)
            } actions: {
                if !model.isDemo { Button("Try Again", action: retry).buttonStyle(.glass) }
            }
        } else {
            DelayedProgress()
        }
    }

    private func retry() {
        failure = nil
        attempt += 1
    }

    private func load() async {
        guard !model.isDemo else {
            if inline == nil { failure = "The demo has no files to open." }
            return
        }
        do {
            let url = try await model.tools.file(SubagentRef(key: sessionID)?.parent ?? sessionID, path: path)
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let type = UTType(filenameExtension: (path as NSString).pathExtension)
            if let type, type.conforms(to: .image), let ref = await model.images.keep(data, mime: type.preferredMIMEType ?? "image/png", name: name) {
                loaded = (url, .image(ref))
            } else {
                loaded = (url, FileKind.of(data, path: path))
            }
        } catch {
            if !Task.isCancelled { failure = MacTools.message(error) }
        }
    }
}

enum DemoFiles {
    static func text(for path: String) -> String? {
        guard path.hasSuffix("cache-plan.md") else { return nil }
        return """
        # Transcript cache

        Open every session at its latest message, from disk, before the network answers.

        ## Shape

        - Eight most recent sessions in memory (LRU).
        - Pages on disk under `Caches/transcripts/<mac>/<session>/`, one JSON file per page.
        - The newest `after` cursor stored beside the pages.

        ## Repair

        A `transcript.append` with a gap fetches `after=` until `hasMoreAfter` is false. A `reset`
        drops the session's folder and starts from the newest page.

        > The stream is for speed, the paged fetch is the truth.
        """
    }
}
